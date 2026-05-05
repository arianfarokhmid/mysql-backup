#!/bin/bash
# ====================================================
# OS Detection and Installation Functions
# ====================================================

# Detect OS and package manager
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    else
        OS="unknown"
    fi
}

# Install missing tools based on OS
install_tools() {
    local missing_tools=("$@")
    
    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        return 0
    fi

    echo "Installing missing tools: ${missing_tools[@]}"
    
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        sudo apt-get update -y
        sudo apt-get install -y "${missing_tools[@]}"
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]] || [[ "$OS" == "fedora" ]]; then
        sudo yum install -y "${missing_tools[@]}"
    else
        echo "ERROR: Unable to determine package manager for OS: $OS"
        return 1
    fi
}

# Install Docker
install_docker() {
    echo "Installing Docker..."
    if [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        sudo apt-get update -y
        sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io
    fi
    
    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker $USER
    echo "Docker installed successfully. You may need to log out and log back in for group changes to take effect."
}

# Install AWS CLI
install_aws_cli() {
    echo "Installing AWS CLI..."
    if command -v pip3 &> /dev/null; then
        pip3 install awscli
    elif command -v pip &> /dev/null; then
        pip install awscli
    else
        echo "ERROR: pip/pip3 not found. Please install Python first."
        return 1
    fi
}