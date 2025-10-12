# Micrio

> [!Warning]
>
> This is a unfinished article. You probably don't want to read it in its current
> state.

So I was reading this article by Shayon Mukherjee yesterday called
[An MVCC-like columnar table on S3 with constant-time deletes](https://www.shayon.dev/post/2025/277/an-mvcc-like-columnar-table-on-s3-with-constant-time-deletes/).
It shows a clever use of the precondition headers on S3 to build a "database".
I'm talking about these things:

* `If-None-Match: *`
* `If-Match: <ETag>`

Obviously, `ETag` is also in the mix. Check
[AWS docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-requests.html)
for some intel on the topic.

This got me thinking. How can a regular Linux file system support semantics like
this? So I started reading up on it. Here is what I figured out. I'm not really
doing any coding (yet), just trying to learn and figure out how one *could* do
it.

> [!NOTE]
>
> I know these things probably shouldn't be dealt with using the file system.
> There are programming language primitives to do these things. But, hey, I
> wanted to learn and explore - so I did.
>
> I know that there are `If-Modified-Since` and `If-Unmodified-Since` headers as
> well. I just didn't want to bother with those.

## Scope

There are a few scenarios we want to explore.

* File exclusivity - only write if the file does not exist.
  `PUT If-None-Match: *`
* [Compare and swap](https://en.wikipedia.org/wiki/Compare-and-swap) - only
  overwrite if the file is the one that I previously read.
  `PUT If-Match: <Etag>`. Aka the lost/interceding update problem
* Compare and serve - only give me the file if it has changed
  `GET If-None-Match: <Etag>`

## The Etag

S3 a MD5 digest for the Entity tag. We want to do that as well. We do *not* want
to compute the MD5 one every request. We want to store it in the file name or as
an attribute on the file.

## The scenario

Multiple processes/clients are reading and writing to the file system
*concurrently*. Lets think about two clients `Ola` and `Kari`. They both want to
access the file `waffle`. Typical issues that might occur are that the file
changes between the compare and serve/swap stage and files are half-changed on read.

> [!NOTE]
>
> I'll be using HTTP-like semantics to describe the access. I am trying to do
> "S3 on a FS" after all.

## The toolbox

I believe that we need to figure out a pattern for how these clients should
interact with the file system. What tools do we have at our disposal? Other than
just file names and directory trees?

### Atomic operations

Atomic operations can help with having clients always seeing consistent states.

> An atomic operation is an operation that will always be executed without any
> other process being able to read or change state that is read or changed
> during the operation. It is effectively executed as a single step
>
> [OSDev.org](https://wiki.osdev.org/Atomic_operation)

Richard Crowley has a nice list of
[Things UNIX can do atomically (2010)](https://rcrowley.org/2010/01/06/things-unix-can-do-atomically.html).
In short

* linking
* symlinking
* moving symlinks
* rename/mv of files
* open file only if it does not exist (`O_EXCL`)
* create directory if not exists (regular mkdir)

## Extended file attributes - xattr

[Extended file attributes](https://en.wikipedia.org/wiki/Extended_file_attributes)
allows us to set name-value pair on files, symlinks and directories.

```sh
setfattr -n user.attr -v "maybeAetag" -h myfile
getfattr -d myfile
```

## File locks

[flock](https://linux.die.net/man/2/flock) and its companion
[flock utility](https://linux.die.net/man/1/flock) are used to apply and remove
advisory locks on an open file.

## A naive approach

Let's invent a starting point and see where it takes us. Let's say that we
create the file and then put the MD5 sum as an attribute.

So Kari and Ola are doing this when they want to create a file.

1. Exclusive open `waffle`
2. Write
3. MD5 digest
4. xattr ETag

Let's say they both do it at the same time. The exclusive open saves the day 🥳
Lets say Kari is first - they get to create the file. Olas attempt will error.

But, wait! What if Ola immediately turns around and want to get the file? Since
the write is non-atomic, there is no guarantee that the file is complete nor
that the ETag is there. Kari might still we writing to the file.

## To lock or not to lock

The first thing that popped into my head was to go with advisory locks. Read?
Shared lock. Write? Exclusive lock. This will probably work, but in our scenario
here, there would be a window of time (write + MD5 digest) between the write
lock was acquired to when the file was ready for read. Also, pessimistic locking
is "meh" 😑. We should be able to do better!

## First one to the finish line

I went back to check the
[AWS docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html#conditional-error-response)
and found what I expected (my emphasis):

> If multiple conditional writes occur [with `If-None-Match: *`] for the same
> object name, the first write operation **to finish** succeeds.

I think this is a good way to go about it. First one to the finish line!

Both Kari and Ola would write files and calculate MD5 at temporary locations,
and race to be the first to claim the `waffle` spot. Enter, the pile!

We now need to start putting objects Somewhere Else™️, and I'm calling that the
pile. We create two directories for our files:

* `/pile` - temporary location for files-being-written
* `/shelf` - where we put the files for display

Now we modify the process to write files with unique names to the pile, e.g.
using [UUID](https://everyuuid.com/) so it becomes `pile/waffle-<uuid>`. Kari
and Ola can then digest and ETag at their own pace. But what mechanism to use
for putting on the shelf?

A rename is atomic but silently overwrites the target. We are after a `EEXIST`
error! Our alternatives are link, symlink, exclusive open and mkdir. I'm
choosing `link` just because it looks like a good idea.

The procedure is now.

1. write file in pile
2. md5 digest and etag
3. link from shelf to pile
4. rm (aka unlink) in pile

But does this work for compare and swap?

## Conditional overwrite

So, by now we have a file structure like this:

* `/pile/` - so much empty
* `/shelf/waffle{user.etag=md5a}` - our file with etag as xattr

Ola wants to do a compare and swap aka `PUT If-Match: md5a`. They can do

1. getfattr user.etag and compare (match!)
2. write file in pile
3. md5 digest and etag
4. rename from pile to shelf

But again? What if concurrent Kari is doing the same stuff at the same time? We
have a race! Thinking about it, all we want is *exclusivity on creating the
successor file*. Maybe we can leverage the same strategy as before: first to the
finish line with a link. But to do that, we probably want the it to be a
symlink. Let's try that.

Below is the dir structure when a client has "prepared" a new file and added the
md5 etag. Note that I've introduced a `box` where we keep earlier versions of files.

* `/pile/uuid-b{user.etag=md5b}` - the new temp file
* `/box/waffle/00000000000000000000000000000000{user.etag=md5a}` - the first
  file (no pre-existing file at create time)
* `/shelf/waffle -> /box/waffle/00000000000000000000000000000000` - symlink from
  the shelf to the box.

The next steps are.

1. move `/pile/uuid-b` to `/box/waffle/md5a` (using link/unlink to get EEXISTS)
2. move the `/shelf/waffle` symlink to `/box/waffle/md5a`

This works, but we have one major problem! What if the process dies between
steps 1 and 2? Since the work is non-atomic, we risk two things:

1. Having a dangling file in the box, effectively blocking future PUTs
2. Inconsistent file serving. Serving and old file.

How can we deal with that?

Well, for point 1, we have forward-referencing files in the box, so we can
recover by following the references (and moving the symlink).
For the other one? Well, I'm stuck!

## TO BE CONTINUED!?

## Filename restrictions due to directory structure

TODO

## License

All code and scripts as well as code examples and snippets in documentation are
licensed under [Zero-Clause BSD](./LICENSE-0BSD). This means you can copy and
use it however you want 🥳 - no strings attached. Documentation and the rest of
the repository is licensed under
[Creative Commons Attribution 4.0 International](./LICENSE-CC-BY-4.0). This
means you can copy, redistribute and adapt it, but it requires attribution.
