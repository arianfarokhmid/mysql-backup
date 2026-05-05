#!/bin/bash
# ====================================================
# MySQL Test and Verification Functions
# ====================================================

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
            return 0
        else
            log "ERROR" "Failed To Clean MySQL Test Dir Data"
            return 1
        fi
    fi
    return 0
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