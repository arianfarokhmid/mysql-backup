#!/bin/bash

MYSQL_BACKUP_DIR=/opt/mysql-inc-dev-backup/backup
MYSQL_DATA_HOST=/opt/mysql/data2/
MYSQL_USER=bkpuser
MYSQL_PASSWORD=jRhBEXFo2waHL23PlocT9szn3ZuN
MYSQL_PORT=3306
MYSQL_HOST=mysql-dev
MYSQL_DOCKER_NETWORK=mysql

CONTAINER_IMAGE=percona/percona-xtrabackup:8.0.35

S3_ENDPOINT=https://s3.thr2.sotoon.ir
S3_BUCKET_NAME=backups
S3_BACKUP_DIR=dev-inc-database
S3_MAX_BACKUPS=2

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() {
    local test_mode=true

    local script_name=$(basename "$0")
    local log_dir="/db-backup/log"
    local log_file="$log_dir/$script_name.log"

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
        if [[ $test_mode == true ]]; then 
            curl -s -X POST "https://gn.azkiloan.com/alerts-test" -H "Content-Type: application/json" -d "$json"
        else
            curl -s -X POST "https://gn.azkiloan.com/alerts" -H "Content-Type: application/json" -d "$json"
        fi
    fi

    echo "$json" | tee -a "$log_file"
}

init_backup_name() {
    if [[ -z $1 ]]; then MYSQL_COMPRESSED_FILTER_FILE=dev; else MYSQL_COMPRESSED_FILTER_FILE=$1; fi
    MYSQL_COMPRESSED_BASE_NAME="${MYSQL_COMPRESSED_FILES_DIR}/${MYSQL_COMPRESSED_FILTER_FILE}"
    MYSQL_COMPRESSED_FILES_NAME="${MYSQL_COMPRESSED_BASE_NAME}-backup-$(date '+%Y-%m-%d_%H-%M').tar.gz"
    MYSQL_COMPRESSED_FILES_DIR=/opt/mysql-inc-dev-backup/final-backups
}

docker_xtrabackup_exec() {
    local extra_args=$1
    docker run -u 999 --rm --network $MYSQL_DOCKER_NETWORK \
        -v "$MYSQL_DATA_HOST":/var/lib/mysql:ro \
        -v "$MYSQL_BACKUP_DIR":/backup \
        -v ./tables:/tmp/tables \
        $CONTAINER_IMAGE \
        xtrabackup --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" --host="$MYSQL_HOST" --port="$MYSQL_PORT" $extra_args
}

apply_log () {
    if ! docker_xtrabackup_exec "--prepare --target-dir=/backup/full"; then 
        log "ERROR" "Failed To Apply Log"
    fi
}

full_backup() {
    local args=$1
    [[ -d "$MYSQL_BACKUP_DIR" ]] || { log "ERROR" "Dir $MYSQL_BACKUP_DIR Not Exist"; exit 1; }
    rm -rf "$MYSQL_BACKUP_DIR"/*
    mkdir -p "$MYSQL_BACKUP_DIR/full"
    if docker_xtrabackup_exec "--backup --target-dir=/backup/full $args"; then 
        if apply_log; then 
            clean_temp_mysql
        fi
    else
        log "ERROR" "Can Create Full Backup"
    fi
}



level1_tables() {
    init_backup_name "high-level-1"
    full_backup --tables-file=/tmp/tables/level1.txt
}

level2_tables() {
    init_backup_name "high-level-2"
    full_backup --tables-file=/tmp/tables/level2.txt
}


clean_temp_mysql() {

    if tar -czvf $MYSQL_COMPRESSED_FILES_NAME $MYSQL_BACKUP_DIR/full; then 
        if rm -rf $MYSQL_BACKUP_DIR/full; then
            log "DONE" "MySQL Full Data Compressed"
        fi
    else
        log "ERROR" "Failed To Compress MySQL Full Data"
    fi


   if clean_files_local; then
       log "DONE" "Clean Old Backups Success"
   else
       log "ERROR" "Clean Old Backups Failed"
   fi

#    if clean_files_s3; then
#        log "DONE" "Clean Old S3 Backups Success"
#    else
#        log "ERROR" "Clean Old S3 Backups Failed"
#    fi

#    if upload_files_s3; then
#        log "DONE" "Upload Backup To S3 Success"
#    else
#        log "ERROR" "Failed To Upload Backup To S3"
#    fi

}

clean_files_local() {
    if [[ $MYSQL_COMPRESSED_RETANTION_DAY -gt 0 ]]; then 
        find "$MYSQL_COMPRESSED_FILES_DIR" -type f -mtime +$MYSQL_COMPRESSED_RETANTION_DAY -exec rm -rf {} \;
    fi  
}

upload_files_s3() {  
    aws s3 --endpoint-url $S3_ENDPOINT cp $MYSQL_COMPRESSED_FILES_NAME s3://$S3_BUCKET_NAME/$S3_BACKUP_DIR/;
}

clean_files_s3() {
    S3_BACKUP_LIST=$(aws s3 --endpoint-url $S3_ENDPOINT ls s3://$S3_BUCKET_NAME/$S3_BACKUP_DIR/ --recursive | sort | grep "${MYSQL_COMPRESSED_FILTER_FILE}-backup")
    S3_BACKUP_COUNT=$(echo "$S3_BACKUP_LIST" | wc -l)

    if [[ $S3_BACKUP_COUNT -gt $S3_MAX_BACKUPS ]]; then
        FILES_TO_DELETE=$((S3_BACKUP_COUNT - S3_MAX_BACKUPS))
        log "WARN" "There are $S3_BACKUP_COUNT backups, exceeding the limit by $FILES_TO_DELETE files."

        FILES_TO_DELETE_LIST=$(echo "$S3_BACKUP_LIST" | head -n $FILES_TO_DELETE | awk '{print $4}')

        for FILE in $FILES_TO_DELETE_LIST; do
            log "INFO" "Deleting the oldest file: $FILE"
            if aws s3 --endpoint-url $S3_ENDPOINT rm s3://$S3_BUCKET_NAME/$FILE; then
                log "DONE" "Deleted: $FILE"
            else
                log "ERROR" "Failed to delete: $FILE"
            fi
        done

        log "DONE" "Cleanup completed. Now there are $S3_MAX_BACKUPS backups."
    else
        log "WARN" "Backup count ($S3_BACKUP_COUNT) is within the limit ($S3_MAX_BACKUPS). No files to delete."
    fi

}


main() {
    if [[ ! -d "$MYSQL_BACKUP_DIR/full" ]]; then
        full_backup
        return
    fi

    if [[ ! -f "$MYSQL_BACKUP_DIR/full/xtrabackup_checkpoints" ]]; then
        full_backup
        return
    fi

}

# main
init_backup_name
level1_tables
