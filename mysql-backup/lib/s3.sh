#!/bin/bash
# ====================================================
# S3 Sync Functions
# ====================================================

upload_files_s3() {  
    aws s3 --endpoint-url $S3_ENDPOINT cp $MYSQL_COMPRESSED_FILES_NAME s3://$S3_BUCKET_NAME/$S3_BACKUP_DIR/
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