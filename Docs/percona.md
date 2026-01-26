# Percona XtraBackup Guide

This guide explains how to install, backup, and restore MySQL databases using **Percona XtraBackup**, including incremental backups and Docker-based workflows.

---

## 1. Install Percona XtraBackup

Update your package list and install the `percona-xtrabackup` package:

```bash
sudo apt update
sudo apt install percona-xtrabackup
```

**Explanation:**

* `percona-xtrabackup` is a hot backup utility for MySQL/MariaDB.
* It allows full and incremental backups without locking the database.

---

## 2. Create a Full Backup

```bash
xtrabackup --backup \
           --target-dir=/sql_backup/full \
           --datadir=/home/radin/MySQL/mysql_data \
           --user=root \
           --password=123 \
           --host=127.0.0.1
```

**Explanation:**

* `--datadir`: Path to the MySQL data directory.
* `--target-dir`: Directory where the backup will be stored.
* `--backup`: Command to create a full backup.

---

## 3. Prepare the Full Backup (Apply Logs)

```bash
xtrabackup --prepare --target-dir=/sql_backup/full
```

**Explanation:**

* Prepares the backup for restoration.
* Applies redo logs to make the backup consistent.
* Without preparing, the backup cannot be restored.

---

## 4. Create an Incremental Backup

```bash
xtrabackup --backup \
           --target-dir=/sql_backup/inc1 \
           --incremental-basedir=/sql_backup/full \
           --datadir=/home/radin/MySQL/mysql_data \
           --user=root \
           --password=123 \
           --host=127.0.0.1
```

**Explanation:**

* `--incremental-basedir`: Specifies the base backup to compare changes against.
* Incremental backups are smaller and faster, storing only changes since the last backup.
* Each incremental must reference the last prepared backup.

---

## 5. Merge Incremental Backups into Full Backup

### Step 1: Prepare Full Backup for Incrementals

```bash
xtrabackup --prepare --apply-log-only --target-dir=/sql_backup/full
```

### Step 2: Apply First Incremental Backup

```bash
xtrabackup --prepare --apply-log-only \
           --target-dir=/sql_backup/full \
           --incremental-dir=/sql_backup/inc1
```

### Step 3: Apply Second Incremental Backup (if any)

```bash
xtrabackup --prepare --apply-log-only \
           --target-dir=/sql_backup/full \
           --incremental-dir=/sql_backup/inc2
```

### Step 4: Finalize Full Backup

```bash
xtrabackup --prepare --target-dir=/sql_backup/full \
           --datadir=/home/radin/mysql/mysql_data2
```

**Explanation:**

* `--apply-log-only` allows merging incremental backups without fully rolling forward.
* Final preparation (`--prepare`) makes the backup ready for restoration.

---

## 6. Restore Backup

### Step 1: Stop MySQL

```bash
sudo systemctl stop mysql
```

### Step 2: Copy Backup Data

```bash
xtrabackup --copy-back --target-dir=/sql_backup/full
```

### Step 3: Fix Permissions

```bash
sudo chown -R mysql:mysql /home/radin/MySQL/mysql_data
```

### Step 4: Start MySQL

```bash
sudo systemctl start mysql
```

**Explanation:**

* MySQL must be stopped during restoration.
* Permissions must match the MySQL user for proper access.

---

## 7. Docker-Based Backup and Restore

### Full Backup

```bash
docker run --rm -u 0 \
    -v mysql_data:/var/lib/mysql \
    -v /opt/mysql-backups:/backups \
    -v mysql_sock:/var/run/mysqld/ \
    percona/percona-xtrabackup:8.0 \
    xtrabackup --backup --user=root --password=123 --target-dir=/backups/full
```

### Prepare Full Backup

```bash
docker run --rm -u 0 \
    -v mysql_data:/var/lib/mysql \
    -v /opt/mysql-backups:/backups \
    -v mysql_sock:/var/run/mysqld/ \
    percona/percona-xtrabackup:8.0 \
    xtrabackup --prepare --target-dir=/backups/full
```

### Incremental Backup

```bash
docker run --rm -u 0 \
    -v mysql_data:/var/lib/mysql \
    -v /opt/mysql-backups:/backups \
    -v mysql_sock:/var/run/mysqld/ \
    percona/percona-xtrabackup:8.0 \
    xtrabackup --backup --user=root --password=123 \
    --target-dir=/backups/inc1 --incremental-basedir=/backups/full
```

### Merge Incremental with Full Backup

```bash
docker run --rm -u 0 \
    -v mysql_data:/var/lib/mysql \
    -v /opt/mysql-backups:/backups \
    -v mysql_sock:/var/run/mysqld/ \
    percona/percona-xtrabackup:8.0 \
    xtrabackup --prepare --apply-log-only \
    --target-dir=/backups/full --incremental-dir=/backups/inc1
```

### Finalize Backup

```bash
docker run --rm -u 0 \
    -v mysql_data:/var/lib/mysql \
    -v /opt/mysql-backups:/backups \
    -v mysql_sock:/var/run/mysqld/ \
    percona/percona-xtrabackup:8.0 \
    xtrabackup --prepare --target-dir=/backups/full
```

### Reset MySQL Data Volume

```bash
docker stop mysql
docker volume rm mysql_data && docker volume create mysql_data
```

### Restore Backup

```bash
docker run --rm -u 0 \
    -v mysql_data:/var/lib/mysql \
    -v /opt/mysql-backups:/backups \
    percona/percona-xtrabackup:8.0 \
    xtrabackup --copy-back --target-dir=/backups/full --datadir=/var/lib/mysql
```

### Start MySQL

```bash
docker start mysql
```

**Explanation:**

* Using Docker, you can perform backups without installing software on the host.
* Volume mounts allow access to MySQL data and backup storage.
* Incremental backups work similarly as in a native environment.

