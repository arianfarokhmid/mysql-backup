#!/bin/bash
# ====================================================
# Prerequisites Check Functions
# ====================================================

check_prerequisites() {
    local missing_tools=()
    local missing_dirs=()
    local auto_install=$1

    echo "Checking prerequisites..."

    local required_commands=("docker" "aws" "jq" "tar" "curl" "grep" "awk" "sed" "find" "flock" "date" "basename" "pigz")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_tools+=("$cmd")
        fi
    done

    if command -v docker &> /dev/null; then
        if ! docker info &> /dev/null; then
            echo "ERROR: Docker daemon is not running"
            exit 1
        fi
    fi

    local required_dirs=(
        "/opt/mysql-inc-dev-backup/backup"
        "/opt/mysql-inc-dev-backup/final-backups"
        "/opt/mysql-inc-dev-backup/mysql-test-backup-data"
        "/db-backup/log"
    )

    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            if mkdir -p "$dir" 2>/dev/null; then
                echo "Created directory: $dir"
            else
                missing_dirs+=("$dir")
            fi
        fi
    done

    if command -v aws &> /dev/null; then
        if ! aws sts get-caller-identity &> /dev/null; then
            echo "WARNING: AWS CLI is not properly configured. S3 operations may fail."
        fi
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "ERROR: The following required tools are missing:"
        printf '%s\n' "${missing_tools[@]}"
        echo ""

        # Check permissions before asking to install
        if ! check_user_permissions; then
            echo "ERROR: Insufficient permissions to install packages."
            echo "You must be root or have sudo access to install missing tools."
            echo ""
            echo "Please do one of the following:"
            echo "  1. Run this script as root: sudo $0 $@"
            echo "  2. Configure sudo to work without a password (contact your system administrator)"
            echo "  3. Manually install the missing tools using your package manager:"
            echo "     Ubuntu/Debian: sudo apt-get install ${missing_tools[@]}"
            echo "     CentOS/RHEL: sudo yum install ${missing_tools[@]}"
            exit 1
        fi
        
        if [[ "$auto_install" == "1" ]]; then
            echo "Auto-install mode enabled. Installing missing tools..."
            detect_os
            install_tools "${missing_tools[@]}"
            if [[ $? -ne 0 ]]; then
                echo "Failed to install some tools. Please install manually."
                exit 1
            fi
        else
            echo "Would you like to install the missing tools automatically? (yes/no)"
            read -r user_response
            
            if [[ "$user_response" == "yes" ]] || [[ "$user_response" == "y" ]]; then
                detect_os
                install_tools "${missing_tools[@]}"
                if [[ $? -ne 0 ]]; then
                    echo "Failed to install some tools. Please install manually."
                    exit 1
                fi
            else
                echo "Please install the missing tools using your package manager:"
                echo "  Ubuntu/Debian: sudo apt-get install ${missing_tools[@]}"
                echo "  CentOS/RHEL: sudo yum install ${missing_tools[@]}"
                exit 1
            fi
        fi
    fi

    # Check if Docker needs installation
    if ! command -v docker &> /dev/null; then
        if ! check_user_permissions; then
            echo "ERROR: Insufficient permissions to install Docker."
            echo "You must be root or have sudo access. Run as: sudo $0 $@"
            exit 1
        fi

        if [[ "$auto_install" == "1" ]]; then
            echo "Auto-install mode enabled. Installing Docker..."
            detect_os
            install_docker
        else
            echo "Docker is not installed. Would you like to install it automatically? (yes/no)"
            read -r user_response
            if [[ "$user_response" == "yes" ]] || [[ "$user_response" == "y" ]]; then
                detect_os
                install_docker
            else
                echo "Please install Docker: https://docs.docker.com/engine/install/"
                exit 1
            fi
        fi
    fi

    # Check if AWS CLI needs installation
    if ! command -v aws &> /dev/null; then
        if ! check_user_permissions; then
            echo "ERROR: Insufficient permissions to install AWS CLI."
            echo "You must be root or have sudo access. Run as: sudo $0 $@"
            exit 1
        fi

        if [[ "$auto_install" == "1" ]]; then
            echo "Auto-install mode enabled. Installing AWS CLI..."
            install_aws_cli
        else
            echo "AWS CLI is not installed. Would you like to install it automatically? (yes/no)"
            read -r user_response
            if [[ "$user_response" == "yes" ]] || [[ "$user_response" == "y" ]]; then
                install_aws_cli
            else
                echo "Please install AWS CLI: pip3 install awscli"
                exit 1
            fi
        fi
    fi

    if [[ ${#missing_dirs[@]} -gt 0 ]]; then
        echo "ERROR: Could not create the following required directories:"
        printf '%s\n' "${missing_dirs[@]}"
        exit 1
    fi

    echo "All prerequisites are satisfied ✓"
}