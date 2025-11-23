#!/bin/bash
MYSQL_BACKUP_DIR=/opt/mysql-backups
MYSQL_DATA_HOST=/opt/mysql/mysql_data
MYSQL_USER=bkpuser
MYSQL_PASSWORD=jRhBEXFo2waHL23PlocT9szn3ZuN
MYSQL_PORT=3306
MYSQL_HOST=mysql
MYSQL_DOCKER_NETWORK="mysql"
CONTAINER_IMAGE=percona/percona-xtrabackup:8.0

docker_xtrabackup() {
    local extra_args=$1
    docker run --rm -u 0 --network $MYSQL_DOCKER_NETWORK \
        -v "$MYSQL_DATA_HOST":/var/lib/mysql:ro \
        -v "$MYSQL_BACKUP_DIR":/backups \
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
        echo "Chain Integrity OK: $prev_dir ($prev_to_lsn) -> $curr_dir ($curr_from_lsn)"
        return 0
    else
        echo "CORRUPTION DETECTED: Chain broken between $prev_dir and $curr_dir"
        echo "Expected: $prev_to_lsn, Found: $curr_from_lsn"
        return 1
    fi
}


apply_log () {
    docker_xtrabackup "--prepare --target-dir=/backups/full"
}

full_backup() {
    if [[ ! -z $MYSQL_BACKUP_DIR ]]; then
        rm -rf "$MYSQL_BACKUP_DIR/*"
        mkdir -p "$MYSQL_BACKUP_DIR/full"
        docker_xtrabackup "--backup --target-dir=/backups/full"
        apply_log
    fi
}

inc_backup() {
    for i in {1..6}; do
        target="$MYSQL_BACKUP_DIR/inc$i"
        if [[ ! -d "$target" ]]; then
            inc_file="$i"
            break
        fi
    done

    if [[ -z "$inc_file" ]]; then
        echo "All incremental slots (1–6) are already used." >&2
        return 1
    fi

    if [[ "$inc_file" -eq 1 ]]; then
        base_bk="full"
    else
        old_inc_file=$((inc_file - 1))
        base_bk="inc$old_inc_file"
    fi

    if docker_xtrabackup "--backup --target-dir=/backups/inc$inc_file --incremental-basedir=/backups/$base_bk"; then
        echo "Done inc$inc_file"
    else
        echo "Incremental backup inc$inc_file failed." >&2
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
    docker_xtrabackup "--prepare  --apply-log-only --target-dir=/backups/full"
    for i in {1..6}; do
        target="$MYSQL_BACKUP_DIR/inc$i"
        if [[ -d "$target" ]]; then
            echo "inc$i"
            docker_xtrabackup "--prepare --apply-log-only --target-dir=/backups/full --incremental-dir=/backups/inc$i"
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

inc_or_full
#merge_inc_to_full
