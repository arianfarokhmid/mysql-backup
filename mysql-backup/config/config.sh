#!/bin/bash
# ====================================================
# MySQL Backup Configuration Variables
# ====================================================

# MySQL Backup Directories
MYSQL_BACKUP_DIR=/opt/mysql-inc-dev-backup/backup
MYSQL_DATA_HOST=/opt/mysql/data2/
MYSQL_COMPRESSED_FILES_DIR=/opt/mysql-inc-dev-backup/final-backups

# MySQL Connection Settings
MYSQL_USER=bkpuser
MYSQL_PASSWORD=jRhBEXFo2waHL23PlocT9szn3ZuN
MYSQL_PORT=3306
MYSQL_HOST=mysql-dev
MYSQL_DOCKER_NETWORK=mysql

# MySQL Test Container Settings
MYSQL_TEST_USERNAME=data_cheker
MYSQL_TEST_PASSWORD=T39EEyFRCCfmeNeQNXMbXVrK
MYSQL_TEST_IMAGE=mysql:8.0.43
MYSQL_TEST_CONTAINER_NAME=mysql-test-backup
MYSQL_TEST_CONTAINER_UID=999
MYSQL_TEST_DATA_DIR=/opt/mysql-inc-dev-backup/mysql-test-backup-data
MYSQL_TEST_NETWORK=mysql-test-backup-net
MYSQL_TEST_HOST_PORT=3309

# Docker Container Image
CONTAINER_IMAGE=percona/percona-xtrabackup:8.0.35

# S3 Configuration
S3_ENDPOINT=https://s3.thr2.sotoon.ir
S3_BUCKET_NAME=backups
S3_BACKUP_DIR=dev-inc-database
S3_MAX_BACKUPS=2

# Backup Retention Settings
MYSQL_COMPRESSED_RETANTION_DAY=7
MAX_INC_BACKUP_COUNT=5

# System PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Logging
LOG_DIR="/db-backup/log"

# Alert Settings
ALERT_TEST_URL="https://gn.azkiloan.com/alerts-test"
ALERT_PROD_URL="https://gn.azkiloan.com/alerts"
ALERT_TEST_MODE=true