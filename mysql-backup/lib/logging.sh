#!/bin/bash
# ====================================================
# Logging Functions
# ====================================================

log() {
    local script_name=$(basename "$0")
    local log_file="$LOG_DIR/$script_name.log"

    local timestamp=$(date -u "+%Y-%m-%d %H:%M")
    local source="${3:-$script_name}"
    local status="$1"
    local message="$2"




    if [[ ! "$status" =~ ^(ERROR|DONE|INFO|WARN)$ ]]; then 
        jq -n --arg ts "$timestamp" --arg src "$source" --arg st "invalid" --arg msg "Invalid status: $status. Allowed: ERROR, DONE, INFO , WARN" \
           '{timestamp: $ts, source: $src, status: $st, message: $msg}' | tee -a "$log_file"
        return 1
    fi

    local json
    json=$(jq -n --arg ts "$timestamp" --arg src "$source" --arg st "$status" --arg msg "$message" \
         '{timestamp: $ts, source: $src, status: $st, message: $msg}')

    # Send alert for ERROR 
    if [[ "$status" == "ERROR" ]]; then
        if [[ $ALERT_TEST_MODE == true ]]; then 
            curl -s -X POST "$ALERT_TEST_URL" -H "Content-Type: application/json" -d "$json"
        else
            curl -s -X POST "$ALERT_PROD_URL" -H "Content-Type: application/json" -d "$json"
        fi
    fi

    echo "$json" | tee -a "$log_file"
}