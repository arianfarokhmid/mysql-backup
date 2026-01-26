#!/bin/bash
MYSQL_BACKUP_DIR=/opt/mysql-inc-dev-backup/backup
MYSQL_DATA_HOST=/opt/mysql/data2/
MYSQL_USER=bkpuser
MYSQL_PASSWORD=jRhBEXFo2waHL23PlocT9szn3ZuN
MYSQL_PORT=3306
MYSQL_HOST=mysql-dev
MYSQL_DOCKER_NETWORK="mysql"

MYSQL_COMPRESSED_FILTER_FILE="dev"
MYSQL_COMPRESSED_FILES_DIR=/opt/mysql-inc-dev-backup/final-backups
MYSQL_COMPRESSED_FILES_NAME="$MYSQL_COMPRESSED_FILES_DIR/$MYSQL_COMPRESSED_FILTER_FILE-backup-$(date '+%Y-%m-%d_%H-%M').tar.gz"
MYSQL_COMPRESSED_RETANTION_DAY=2
CONTAINER_IMAGE=percona/percona-xtrabackup:8.0.35

S3_ENDPOINT="https://s3.thr2.sotoon.ir"
S3_BUCKET_NAME="backups"
S3_BACKUP_DIR="dev-inc-database"
S3_MAX_BACKUPS=2

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() {
    local test_mode=false

    local script_name=$(basename "$0")
    local log_dir="/opt/mysql-inc-dev-backup/logs"
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


docker_xtrabackup_exec() {
    local extra_args=$1
    docker run -u 999 --rm --network $MYSQL_DOCKER_NETWORK \
        -v "$MYSQL_DATA_HOST":/var/lib/mysql:ro \
        -v "$MYSQL_BACKUP_DIR":/backup \
        -v "$MYSQL_TEST_DATA_DIR":/var/lib/mysql_new:rw \
        $CONTAINER_IMAGE \
        xtrabackup --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" --host="$MYSQL_HOST" --port="$MYSQL_PORT" $extra_args
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





merge_inc_to_full() {
    local merge_state
    docker_xtrabackup_exec "--prepare  --apply-log-only --target-dir=/backup/full"
    for (( i=1; i<=MAX_INC_BACKUP_COUNT; i++ )); do
        target="$MYSQL_BACKUP_DIR/inc$i"
        if [[ -d "$target" ]]; then
            if docker_xtrabackup_exec "--prepare --apply-log-only --target-dir=/backup/full --incremental-dir=/backup/inc$i"; then
                log "INFO" "Incremental backup inc$i merged with full"
                merge_state=true
                mv $target "$MYSQL_BACKUP_DIR/merged_inc$i"
            else
                log "WARN" "Merge with full Incremental backup inc$i failed"
                merge_state=false
            fi
        fi
    done    

    if [[ "$merge_state" == true ]]; then 
        apply_log
    else
        log "ERROR" "Incremental backup Merges Failed"
        exit 1;
    fi
    
}



clean_temp_mysql() {
    
    if tar -czvf $MYSQL_COMPRESSED_FILES_NAME $MYSQL_BACKUP_DIR/full; then 
        log "DONE" "MySQL Full Data Compressed"
        rm -rf $MYSQL_BACKUP_DIR/full
        for (( i=1; i<=MAX_INC_BACKUP_COUNT; i++ )); do
            target="$MYSQL_BACKUP_DIR/merged_inc$i"
            if [[ -d "$target" ]]; then
                rm -rf $target
            fi
        done
    else
        log "ERROR" "Failed To Compress MySQL Full Data"
    fi


    if clean_files_local; then
        log "DONE" "Clean Old Backups Success"
    else
        log "ERROR" "Clean Old Backups Failed"
    fi

    if clean_files_s3; then
        log "DONE" "Clean Old S3 Backups Success"
    else
        log "ERROR" "Clean Old S3 Backups Failed"
    fi

    if upload_files_s3; then
        log "DONE" "Upload Backup To S3 Success"
    else
        log "ERROR" "Failed To Upload Backup To S3"
    fi

}

clean_files_local() {
    local max_days=$MYSQL_COMPRESSED_RETANTION_DAY
    local cleanup_dir=$MYSQL_COMPRESSED_FILES_DIR

    if [[ $max_days -gt 0 ]]; then 
        find "$cleanup_dir" -type f -mtime +$max_days -exec rm -rf {} \;
    fi  
}

upload_files_s3() {  
    aws s3 --endpoint-url $S3_ENDPOINT cp $MYSQL_COMPRESSED_FILES_NAME s3://$S3_BUCKET_NAME/$S3_BACKUP_DIR/;
}

clean_files_s3() {
    S3_BACKUP_LIST=$(aws s3 --endpoint-url $S3_ENDPOINT ls s3://$S3_BUCKET_NAME/$S3_BACKUP_DIR/ --recursive | sort | grep '$MYSQL_COMPRESSED_FILTER_FILE-backup')
    S3_BACKUP_COUNT=$(echo "$S3_BACKUP_LIST" | wc -l)

    if [[ $S3_BACKUP_COUNT -gt $S3_MAX_BACKUPS ]]; then
        FILES_TO_DELETE=$((S3_BACKUP_COUNT - S3_MAX_BACKUPS))
        log "There are $S3_BACKUP_COUNT backups, exceeding the limit by $FILES_TO_DELETE files."

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
}

main