#!/bin/bash
MYSQL_BACKUP_DIR=/opt/mysql-inc-dev-backup/backup
MYSQL_DATA_HOST=/opt/mysql/data2/
MYSQL_USER=bkpuser
MYSQL_PASSWORD=jRhBEXFo2waHL23PlocT9szn3ZuN
MYSQL_PORT=3306
MYSQL_HOST=mysql-dev
MYSQL_DOCKER_NETWORK="mysql"

MYSQL_TEST_USERNAME="data_cheker"
MYSQL_TEST_PASSWORD="T39EEyFRCCfmeNeQNXMbXVrK"
MYSQL_TEST_IMAGE="mysql:8.0.43"
MYSQL_TEST_CONTAINER_NAME="mysql-test-backup"
MYSQL_TEST_CONTAINER_UID="999"
MYSQL_TEST_DATA_DIR="/opt/mysql-inc-dev-backup/mysql-test-backup-data"
MYSQL_TEST_NETWORK="mysql-test-backup-net"
MYSQL_TEST_HOST_PORT="3309"

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

MAX_INC_BACKUP_COUNT=1

log() {
    local test_mode=true

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
    if ! docker_xtrabackup_exec "--prepare --target-dir=/backup/full"; then 
        log "ERROR" "Failed To Apply Log"
    fi
}

full_backup() {
    [[ -d "$MYSQL_BACKUP_DIR" ]] || { log "ERROR" "Dir $MYSQL_BACKUP_DIR Not Exist"; exit 1; }
    rm -rf "$MYSQL_BACKUP_DIR"/*
    mkdir -p "$MYSQL_BACKUP_DIR/full"
    if docker_xtrabackup_exec "--backup --target-dir=/backup/full"; then 
        apply_log
    else
        log "ERROR" "Can Create Full Backup"
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
        return 0;
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
    for inc_dir in $( ls -d $MYSQL_BACKUP_DIR/inc* | sort -V);
    do
        if [[ -d $inc_dir ]]; then 
            if [[ -e $inc_dir/xtrabackup_checkpoints  ]]; then
                if [[ -n $latest_inc_dir ]]; then
                    verify_chain $latest_inc_dir $inc_dir 
                fi
            else
                log "ERROR" "Dir $inc_dir Have Some Issue"
                return 1
            fi
            latest_inc_dir=$inc_dir
        fi 
    done
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

check_mysql_state() {
    local retries=240
    for i in $(seq 1 "$retries"); do
        if docker exec -it $MYSQL_TEST_CONTAINER_NAME mysql -u $MYSQL_TEST_USERNAME -p"$MYSQL_TEST_PASSWORD" -D azki_loan -e "select * from ticket order by id desc LIMIT 10;"; then
            return 0
        fi
        sleep 1
    done
    return 1 
}

check_temp_mysql_dir() {
    if ! [ -z "$(ls -A $MYSQL_TEST_DATA_DIR)" ]; then
        if rm -rf $MYSQL_TEST_DATA_DIR/*; then 
            log "DONE" "MySQL Test Dir Cleaned"
        else
            log "ERROR" "Failed To Clean MySQL Test Dir Data"
        fi
    fi
}

setup_temp_mysql() {
    if docker_xtrabackup_exec "--copy-back --target-dir=/backup/full --datadir=/var/lib/mysql_new"; then 
        if docker network create "${MYSQL_TEST_NETWORK}"; then
            docker run -d \
                --user "${MYSQL_TEST_CONTAINER_UID}" \
                --name "${MYSQL_TEST_CONTAINER_NAME}" \
                --volume "${MYSQL_TEST_DATA_DIR}:/var/lib/mysql" \
                --network "${MYSQL_TEST_NETWORK}" \
                --publish "${MYSQL_TEST_HOST_PORT}:3306" \
                "${MYSQL_TEST_IMAGE}"
            if check_mysql_state; then 
                clean_temp_mysql
                log "DONE" "Test Data On MySQL Temp Successfully"
            else
                clean_temp_mysql
                log "ERROR" "Can Not Excute Test Data On MySQL Temp"
                exit 1;
            fi
        else
            log "ERROR" "Failed To Create MySQL Test Network"
        fi
    else
        log "ERROR" "Failed To Copy Backup Data To MySQL Test Container"
    fi
}


clean_temp_mysql() {
    if docker rm -f "${MYSQL_TEST_CONTAINER_NAME}"; then
        log "DONE" "MySQL Temp Docker Container Removed"
    else
        log "ERROR" "Cannot Remove MySQL Temp Docker Container"
        exit 1;
    fi

    if docker network rm "${MYSQL_TEST_NETWORK}"; then
        log "DONE" "MySQL Temp Docker Network Removed"
    else
        log "ERROR" "Cannot Remove MySQL Temp Docker Network"
        exit 1;
    fi


    if find "$MYSQL_TEST_DATA_DIR" -mindepth 1 -delete; then
        log "DONE" "MySQL Temp Docker Data Removed"
    else
        log "ERROR" "Failed To Remove MySQL Temp Docker Data"
        exit 1;
    fi


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
    if [[ $MYSQL_COMPRESSED_RETANTION_DAY -gt 0 ]]; then 
        find "$MYSQL_COMPRESSED_FILES_DIR" -type f -mtime +$MYSQL_COMPRESSED_RETANTION_DAY -exec rm -rf {} \;
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

    local merged_inc_files=$(find "$MYSQL_BACKUP_DIR" -maxdepth 1 -name '*merged_inc*' | wc -l)

    if [[ ! -d "$MYSQL_BACKUP_DIR/full" ]]; then
        full_backup
        return
    fi

    if [[ ! -f "$MYSQL_BACKUP_DIR/full/xtrabackup_checkpoints" ]]; then
        full_backup
        return
    fi

    if [[ "$merged_inc_files" -eq "$MAX_INC_BACKUP_COUNT" ]]; then
        if check_temp_mysql_dir; then
            setup_temp_mysql
        fi
        return
    fi

    if checks_inc_backups; then
        inc_backup
    fi
}

main
