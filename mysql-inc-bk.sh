#!/bin/bash
MYSQL_BACKUP_DIR=/database/inc-backup
MYSQL_DATA_HOST=/db-data
MYSQL_USER=inc_backuper
MYSQL_PASSWORD=pass
MYSQL_PORT=3306
MYSQL_HOST=127.0.0.1
MYSQL_DOCKER_NETWORK="host"

CONTAINER_IMAGE=percona/percona-xtrabackup:8.0.35

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MAX_INC_BACKUP_COUNT=3

SCRIPT_NAME=$(basename "$0")
SCRIPT_LOG_FILE="/var/log/$SCRIPT_NAME-$(date '+%Y-%m-%d_%H-%M').log"

log() {
    local timestamp
    timestamp=$(date -u "+%Y-%m-%d %H:%M")
    local source="${3:-$SCRIPT_NAME}"
    local status="$1"
    local message="$2"

    if [[ ! "$status" =~ ^(ERROR|DONE|INFO)$ ]]; then 
        jq -n --arg ts "$timestamp" --arg src "$source" --arg st "invalid" --arg msg "Invalid status: $status. Allowed: ERROR, DONE, INFO" \
           '{timestamp: $ts, source: $src, status: $st, message: $msg}' | tee -a "$SCRIPT_LOG_FILE"
        return 1
    fi

    local json
    json=$(jq -n --arg ts "$timestamp" --arg src "$source" --arg st "$status" --arg msg "$message" \
         '{timestamp: $ts, source: $src, status: $st, message: $msg}')

    # Send alert for ERROR or DONE
    if [[ "$status" == "ERROR" ]]; then
        curl -s -X POST "https://gn.azkiloan.com/alerts-test" -H "Content-Type: application/json" -d "$json"
    fi

    echo "$json" | tee -a "$SCRIPT_LOG_FILE"
}


docker_xtrabackup_exec() {
    local extra_args=$1
    docker run -u 999 --rm --network $MYSQL_DOCKER_NETWORK \
        -v "$MYSQL_DATA_HOST":/var/lib/mysql:ro \
        -v "$MYSQL_BACKUP_DIR":/backup \
        $CONTAINER_IMAGE \
        xtrabackup --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" --host="$MYSQL_HOST" --port="$MYSQL_PORT" $extra_args
}

verify_chain() {
    local prev_dir=$1
    local curr_dir=$2

    # Extract LSNs using grep and awk
    local prev_to_lsn=$(grep "to_lsn" "$prev_dir/xtrabackup_checkpoints" | awk '{print $3}')
    local curr_from_lsn=$(grep "from_lsn" "$curr_dir/xtrabackup_checkpoints" | awk '{print $3}')

    if [[ "$prev_to_lsn" == "$curr_from_lsn" ]]; then
        log "INFO" "Chain Integrity OK: $prev_dir ($prev_to_lsn) -> $curr_dir ($curr_from_lsn)"
        return 0
    else
        log "ERROR" "CORRUPTION DETECTED: Chain broken between $prev_dir and $curr_dir"
        log "ERROR" "Expected: $prev_to_lsn, Found: $curr_from_lsn"
        return 1
    fi
}


apply_log () {
    docker_xtrabackup_exec "--prepare --target-dir=/backup/full"
}

full_backup() {
    [[ -d "$MYSQL_BACKUP_DIR" ]] || { log "ERROR" "Dir $MYSQL_BACKUP_DIR Not Exist"; exit 1; }
    rm -rf "$MYSQL_BACKUP_DIR"/*
    mkdir -p "$MYSQL_BACKUP_DIR/full"
    docker_xtrabackup_exec "--backup --target-dir=/backup/full"
    apply_log
}

inc_backup() {
    for (( i=1; i<=MAX_INC_BACKUP_COUNT; i++ )); do
        target="$MYSQL_BACKUP_DIR/inc$i"
        if [[ ! -d "$target" ]]; then
            inc_file="$i"
            break
        fi
    done

    if [[ -z "$inc_file" ]]; then
        log "ERROR" "All incremental slots (1–$MAX_INC_BACKUP_COUNT) are already used." >&2
        return 1
    fi

    if [[ "$inc_file" -eq 1 ]]; then
        base_bk="full"
    else
        old_inc_file=$((inc_file - 1))
        base_bk="inc$old_inc_file"
    fi

    if docker_xtrabackup_exec "--backup --target-dir=/backup/inc$inc_file --incremental-basedir=/backup/$base_bk"; then
        log "INFO" "Incremental backup inc$inc_file successfully"
    else
        log "ERROR" "Incremental backup inc$inc_file failed." >&2
        return 1
    fi
}


checks_inc_backups() {
    for inc_dir in $MYSQL_BACKUP_DIR/inc*
    do
        if [[ -e $inc_dir/xtrabackup_checkpoints  ]]; then
            if [[ -n $latest_inc_dir ]]; then
                verify_chain $latest_inc_dir $inc_dir 
            fi
        fi
        latest_inc_dir=$inc_dir
    done
}


merge_inc_to_full() {
    docker_xtrabackup_exec "--prepare  --apply-log-only --target-dir=/backup/full"
    for (( i=1; i<=MAX_INC_BACKUP_COUNT; i++ )); do
        target="$MYSQL_BACKUP_DIR/inc$i"
        if [[ -d "$target" ]]; then
            if docker_xtrabackup_exec "--prepare --apply-log-only --target-dir=/backup/full --incremental-dir=/backup/inc$i"; then
                log "INFO" "Incremental backup inc$i merged with full"
            else
                log "ERROR" "Merge with full Incremental backup inc$i failed"
                exit 1;
            fi
        fi
    done
    apply_log
}



inc_or_full() {
    if [[ -d "$MYSQL_BACKUP_DIR/full/" ]]; then
        if [[ ! -e "$MYSQL_BACKUP_DIR/full/xtrabackup_checkpoints" ]]; then 
            full_backup
        else
            checks_inc_backups && inc_backup
        fi
    else
        full_backup
    fi

}


ACTION=$1

case "$ACTION" in
    "inc")
        inc_or_full
    ;;
    "merge")
        merge_inc_to_full
    ;;
    *)
        log "ERROR" "Incorrect Input Script"
    ;;
esac
