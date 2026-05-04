#!/bin/bash

# -------------------------
# variables
# -------------------------
MYSQL_BACKUP_DIR=/opt/mysql-inc-dev-backup/backup
MYSQL_DATA_HOST=/opt/mysql/data2/
MYSQL_USER=bkpuser
MYSQL_PASSWORD=jRhBEXFo2waHL23PlocT9szn3ZuN
MYSQL_PORT=3306
MYSQL_HOST=mysql-dev
MYSQL_DOCKER_NETWORK=mysql

MYSQL_TEST_USERNAME=data_cheker
MYSQL_TEST_PASSWORD=T39EEyFRCCfmeNeQNXMbXVrK
MYSQL_TEST_IMAGE=mysql:8.0.43
MYSQL_TEST_CONTAINER_NAME=mysql-test-backup
MYSQL_TEST_CONTAINER_UID=999
MYSQL_TEST_DATA_DIR=/opt/mysql-inc-dev-backup/mysql-test-backup-data
MYSQL_TEST_NETWORK=mysql-test-backup-net
MYSQL_TEST_HOST_PORT=3309

CONTAINER_IMAGE=percona/percona-xtrabackup:8.0.35

S3_ENDPOINT=https://s3.thr2.sotoon.ir
S3_BUCKET_NAME=backups
S3_BACKUP_DIR=dev-inc-database
S3_MAX_BACKUPS=2

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# --------------------------
# Lock function
# --------------------------
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

if [[ "$1" != "--help" ]]; then
    acquire_lock
fi
# --------------------------
# Help Function
# --------------------------
show_help() {
cat <<EOF
Usage: $0 [OPTIONS]

Backup Options:
  --full                     Run full backup
  --incremental              Run incremental backup
  --priority                 Specify a table priority

General Options:
  --help                     Show this help message
  --verbose                  Enable verbose output

Examples:
  $0 --full
  $0 --priority 1/2/3/4    
  $0 --incremental
EOF
}
# --------------------------
# Default variables
# --------------------------
MODE=""
TABLE_LABEL=""
VERBOSE=0
# --------------------------
# Argument Parser
# --------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
        show_help
        exit 0
        ;;
    --full)
        MODE="full"
        fullbackup_name="$2"
        shift
        ;;
    --incremental)
        MODE="incremental"
        ;;
    --priority)
        if [[ "$2" != "1" && "$2" != "2" ]]; then
            echo "Error: --priority must be 1 or 2"
            exit 1
        fi

        if [[ -n "$3" && "$3" != --* ]]; then
            echo "Error: --priority accepts only one value"
            exit 1
        fi

        MODE="$2"
        shift

        ;;
    --verbose)
        VERBOSE=1
        ;;
    *)
        echo "Error: Unknown option '$1'"
        echo "Use --help for usage."
        exit 1
        ;;
  esac
  shift
done


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

# -- Basic Full Backup -- #

first_backup() {
    local args=$1
    [[ -d "$MYSQL_BACKUP_DIR" ]] || { log "ERROR" "Dir $MYSQL_BACKUP_DIR Not Exist"; exit 1; }
    rm -rf "$MYSQL_BACKUP_DIR"/*
    mkdir -p "$MYSQL_BACKUP_DIR/full"
    if docker_xtrabackup_exec "--backup --target-dir=/backup/full $args"; then 
        if apply_log; then 
            log "DONE" "First Backup Created"
        fi
    else
        log "ERROR" "Can Create First Backup"
    fi
}

## -- full_backup -- ##

full_backup() {
    if first_backup; then 
        finialize_backup
    fi
}


## -- Table Level Backup -- #


level1_tables() {
    echo "level1 priority backup started ..."
    init_backup_name "high-level-1"
    first_backup --tables-file=/tmp/tables/level1.txt
}

level2_tables() {
    init_backup_name "high-level-2"
    first_backup --tables-file=/tmp/tables/level2.txt
}



# -- Incremental Functions -- #

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




# -- Test Final Backup File -- #

check_mysql_state() {
    local retries=240
    local attempt=1

    while [ "$attempt" -le "$retries" ]; do
        if docker exec -i "${MYSQL_TEST_CONTAINER_NAME}" mysql \
            -u "${MYSQL_TEST_USERNAME}" \
            -p"${MYSQL_TEST_PASSWORD}" \
            -D "azki_loan" \
            -e "SELECT * FROM ticket ORDER BY id DESC LIMIT 10;" &> /dev/null; 
        then
            return 0
        fi
        
        sleep 1
        ((attempt++))
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

    if ! docker_xtrabackup_exec "--copy-back --target-dir=/backup/full --datadir=/var/lib/mysql_new"; then 
        log "ERROR" "Failed To Copy Backup Data To MySQL Test Container"
        exit 1
    fi

    if ! docker network create "${MYSQL_TEST_NETWORK}"; then
        log "ERROR" "Failed To Create MySQL Test Network"
        exit 1
    fi

    docker run -d \
        --user "${MYSQL_TEST_CONTAINER_UID}" \
        --name "${MYSQL_TEST_CONTAINER_NAME}" \
        --volume "${MYSQL_TEST_DATA_DIR}:/var/lib/mysql" \
        --network "${MYSQL_TEST_NETWORK}" \
        --publish "${MYSQL_TEST_HOST_PORT}:3306" \
        "${MYSQL_TEST_IMAGE}"

    if check_mysql_state; then 
        finialize_backup
        log "DONE" "Test Data On MySQL Temp Successfully"
    else
        finialize_backup
        log "ERROR" "Cannot Execute Test Data On MySQL Temp"
        exit 1
    fi
}


finialize_backup() {
    clean_files_local
    compress_files
    s3_sync

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
        if find "$MYSQL_COMPRESSED_FILES_DIR" -type f -mtime +$MYSQL_COMPRESSED_RETANTION_DAY -exec rm -rf {} \; then
            log "DONE" "Clean Old Backups Success"
        else
            log "ERROR" "Clean Old Backups Failed"
        fi
    fi  
}


# -- S3 functions -- #

s3_sync() {

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


incremental () {
    init_backup_name
    if [[ ! -d "${MYSQL_BACKUP_DIR}/full" ]] || [[ ! -f "${MYSQL_BACKUP_DIR}/full/xtrabackup_checkpoints" ]]; then
        first_backup
        return
    fi

    if [[ "${merged_inc_files}" -eq "${MAX_INC_BACKUP_COUNT}" ]]; then
        if check_temp_mysql_dir; then
            setup_temp_mysql
        fi
        return
    fi

    if checks_inc_backups; then
        inc_backup
    fi
}

# --------------------------
# Execute Logic
# --------------------------
if [[ "$VERBOSE" -eq 1 ]]; then
    echo "Mode = $MODE"
    echo "Table Label = $TABLE_LABEL"
fi

case "$MODE" in
  full)
      fullbackup $fullbackup_name  # your function
      ;;
  incremental)
      #incremental_backup   # your function
      inc_backup 
      ;;
  
  1)
      level1_tables
      ;;
  
  2)
      level2_tables
      ;;
  
  "")
      echo -e "Error: You must specify --full or --incremental or --priority\nUse --help for more"
      exit 1
      ;;
esac
