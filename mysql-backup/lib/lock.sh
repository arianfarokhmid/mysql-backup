#!/bin/bash
# ====================================================
# Lock Management Functions
# ====================================================

acquire_lock() {
    local lock_name="${1:-$(basename "$0")}"
    local lock_file="/tmp/${lock_name}.lock"

    exec 200>"$lock_file"

    if ! flock -n 200; then
        echo "{\"timestamp\":\"$(date -u "+%Y-%m-%d %H:%M")\",\"source\":\"$(basename "$0")\",\"status\":\"ERROR\",\"message\":\"Another instance of this script is already running\"}"
        exit 1
    fi

    trap 'flock -u 200' EXIT
}