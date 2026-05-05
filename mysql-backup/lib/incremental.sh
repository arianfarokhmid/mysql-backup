#!/bin/bash
# ====================================================
# Incremental Backup Functions
# ====================================================

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

inc_backup() {
    for (( i=1; i<=MAX_INC_BACKUP_COUNT; i++ )); do
        target="$MYSQL_BACKUP_DIR/inc$i"
        if [[ ! -d "$target" ]]; then
            inc_file="$i"
            break
        fi
    done

    if [[ -z "$inc_file" ]]; then
        log "WARN" "All incremental slots (1–$MAX_INC_BACKUP_COUNT) are already used."  
        merge_inc_to_full
        return 0
    fi

    if [[ "$inc_file" -eq 1 ]]; then
        base_bk="full"
    else
        old_inc_file=$((inc_file - 1))
        base_bk="inc$old_inc_file"
    fi

    if docker_xtrabackup_exec "--backup --target-dir=/backup/inc$inc_file --incremental-basedir=/backup/$base_bk"; then
        log "INFO" "Incremental backup inc$inc_file successfully"
        return 0
    else
        log "ERROR" "Incremental backup inc$inc_file failed."
        return 1
    fi
}

checks_inc_backups() {
    local latest_inc_dir=""
    
    for inc_dir in $( ls -d $MYSQL_BACKUP_DIR/inc* 2>/dev/null | sort -V); do
        if [[ -d $inc_dir ]]; then 
            if [[ -e $inc_dir/xtrabackup_checkpoints ]]; then
                if [[ -n $latest_inc_dir ]]; then
                    verify_chain $latest_inc_dir $inc_dir || return 1
                fi
            else
                log "ERROR" "Dir $inc_dir Have Some Issue"
                return 1
            fi
            latest_inc_dir=$inc_dir
        fi 
    done
    return 0
}

merge_inc_to_full() {
    if ! docker_xtrabackup_exec "--prepare --apply-log-only --target-dir=/backup/full"; then
        log "ERROR" "Failed to prepare base full backup"
        exit 1
    fi

    for (( i=1; i<=MAX_INC_BACKUP_COUNT; i++ )); do
        local target="$MYSQL_BACKUP_DIR/inc$i"
        
        if [[ -d "$target" ]]; then
            if docker_xtrabackup_exec "--prepare --apply-log-only --target-dir=/backup/full --incremental-dir=/backup/inc$i"; then
                log "INFO" "Incremental backup inc$i merged with full"
                mv "$target" "$MYSQL_BACKUP_DIR/merged_inc$i"
            else
                log "ERROR" "Merge with full Incremental backup inc$i failed"
                exit 1
            fi
        fi
    done    

    apply_log
}

incremental() {
    init_backup_name
    if [[ ! -d "${MYSQL_BACKUP_DIR}/full" ]] || [[ ! -f "${MYSQL_BACKUP_DIR}/full/xtrabackup_checkpoints" ]]; then
        first_backup
        return $?
    fi

    if [[ "${merged_inc_files}" -eq "${MAX_INC_BACKUP_COUNT}" ]]; then
        if check_temp_mysql_dir; then
            setup_temp_mysql
        fi
        return $?
    fi

    if checks_inc_backups; then
        inc_backup
        return $?
    fi
    return 1
}