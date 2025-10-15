#!/bin/bash

# Install pre-commit if not already installed
if ! command -v pre-commit &> /dev/null; then
    echo "Installing pre-commit..."
    pip install pre-commit
fi

# Install the pre-commit hooks
pre-commit install

echo "Pre-commit hooks installed successfully!"
echo "The hooks will run automatically on every commit."
echo "You can also run them manually with: pre-commit run --all-files"