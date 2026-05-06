#!/bin/bash
# ====================================================
# User Permissions Check Functions
# ====================================================

check_user_permissions() {
    if [[ $EUID -eq 0 ]]; then
        # User is root
        return 0
    fi

    if sudo -n true 2>/dev/null; then
        return 0
    fi

    if sudo -l &>/dev/null; then
        return 0
    fi

    return 1
}