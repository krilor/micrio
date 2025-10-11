# initialize the project
init:
    pre-commit install

# lint all-the-things
lint:
    pre-commit run --all-files
