#!/bin/bash

# Function to check for a command
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install a package
install_package() {
    if [[ "$OSTYPE" == "linux-gnu" ]]; then
        sudo apt-get install -y "$1"
    elif [[ "$OSTYPE" == "darwin" ]]; then
        brew install "$1"
    else
        echo "Unsupported OS. Please install $1 manually."
        exit 1
    fi
}

# Check for required dependencies
required_packages=(
    git
    mysql-client
    # Add more packages as needed
)

for package in "${required_packages[@]}"; do
    if ! check_command "$package"; then
        echo "$package is not installed. Installing..."
        install_package "$package"
    else
        echo "$package is already installed."
    fi
done
