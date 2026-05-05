#!/bin/bash
# ====================================================
# User Permissions Check Functions
# ====================================================

check_user_permissions() {
    if [[ $EUID -eq 0 ]]; then
        # User is root
        return 0
    fi

    # Check if user has sudo access without password
    if sudo -n true 2>/dev/null; then
        return 0
    fi

    # Check if user can use sudo (with password)
    if sudo -l &>/dev/null; then
        return 0
    fi

    return 1
}