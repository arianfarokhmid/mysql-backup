#!/bin/bash
# ====================================================
# Backup Functions
# ====================================================

init_backup_name() {
    if [[ -z $1 ]]; then 
        MYSQL_COMPRESSED_FILTER_FILE=dev
    else 
        MYSQL_COMPRESSED_FILTER_FILE=$1
    fi
    MYSQL_COMPRESSED_FILES_DIR=/db-backup/level_backup
    MYSQL_COMPRESSED_BASE_NAME="${MYSQL_COMPRESSED_FILES_DIR}/${MYSQL_COMPRESSED_FILTER_FILE}"
    MYSQL_COMPRESSED_FILES_NAME="${MYSQL_COMPRESSED_BASE_NAME}-backup-$(date '+%Y-%m-%d_%H-%M').tar.gz"
    MYSQL_TABLES_BACKUP_DIR=/opt/scripts/priority-database/tables
}

docker_xtrabackup_exec() {
    local extra_args=$1
    docker run -u 999 --rm --network $MYSQL_DOCKER_NETWORK \
        -v "$MYSQL_DATA_HOST":/var/lib/mysql:ro \
        -v "$MYSQL_BACKUP_DIR":/backup \
        -v "$MYSQL_TABLES_BACKUP_DIR":/tmp/tables \
        $CONTAINER_IMAGE \
        xtrabackup --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" --host="$MYSQL_HOST" --port="$MYSQL_PORT" $extra_args
}

apply_log () {
    if ! docker_xtrabackup_exec "--prepare --target-dir=/backup/full"; then 
        log "ERROR" "Failed To Apply Log"
        return 1
    fi
    return 0
}

first_backup() {
    local args=$1
    [[ -d "$MYSQL_BACKUP_DIR" ]] || { log "ERROR" "Dir $MYSQL_BACKUP_DIR Not Exist"; exit 1; }
    rm -rf "$MYSQL_BACKUP_DIR"/*
    mkdir -p "$MYSQL_BACKUP_DIR/full"
    if docker_xtrabackup_exec "--backup --target-dir=/backup/full $args"; then 
        if apply_log; then 
            log "DONE" "First Backup Created"
            return 0
        fi
    else
        log "ERROR" "Can Create First Backup"
        rm -rf "$MYSQL_BACKUP_DIR"/*
        return 1
    fi
}

full_backup() {
    if first_backup; then 
        finialize_backup
        return 0
    fi
    return 1
}

level1_tables() {

    init_backup_name "high-level-1"
    if first_backup --tables-file=/tmp/tables/level1.txt; then
        finialize_backup
    fi
    
}

level2_tables() {
    init_backup_name "high-level-2"
    if first_backup --tables-file=/tmp/tables/level2.txt; then
        finialize_backup
    fi
    
}

compress_files() {
    if ! tar -czvf "${MYSQL_COMPRESSED_FILES_NAME}" "${MYSQL_BACKUP_DIR}/full"; then 
        log "ERROR" "Failed to Compress MySQL Full Data"
        exit 1
    fi

    if ! rm -rf "${MYSQL_BACKUP_DIR}/full"; then
        log "ERROR" "Failed to remove original full backup directory after compression"
        exit 1
    fi

    log "DONE" "MySQL Full Data Compressed"
}

clean_files_local() {
    if [[ $MYSQL_COMPRESSED_RETANTION_DAY -gt 0 ]]; then 
        if find "$MYSQL_COMPRESSED_FILES_DIR" -type f -mtime +$MYSQL_COMPRESSED_RETANTION_DAY -exec rm -rf {} \;; then
            log "DONE" "Clean Old Backups Success"
        else
            log "ERROR" "Clean Old Backups Failed"
        fi
    fi  
}