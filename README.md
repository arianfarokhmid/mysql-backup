# Percona XtraBackup Backup & Restore Guide

## 1. Install Percona XtraBackup

```bash
sudo apt update
sudo apt install percona-xtrabackup
````

---

## 2. Create a Full Backup

```bash
xtrabackup \
  --backup \
  --target-dir=/sql_backup/full \
  --datadir=/home/radin/MySQL/mysql_data \
  --user=root \
  --password=123 \
  --host=127.0.0.1
```

**Notes:**

* `--datadir` → Actual MySQL data directory
* `--target-dir` → Location where the backup will be stored

---

## 3. Prepare Full Backup (Apply Logs)

```bash
xtrabackup --prepare --target-dir=/sql_backup/full
```

---

## 4. Create Incremental Backup

```bash
xtrabackup \
  --backup \
  --target-dir=/sql_backup/inc1 \
  --incremental-basedir=/sql_backup/full \
  --datadir=/home/radin/MySQL/mysql_data \
  --user=root \
  --password=123 \
  --host=127.0.0.1
```

**Important:**
Each incremental backup must reference the last prepared backup.

---

## 5. Merge Incremental Backups

### Step 1: Prepare Full Backup for Incrementals

```bash
xtrabackup --prepare --apply-log-only --target-dir=/sql_backup/full
```

### Step 2: Apply First Incremental Backup

```bash
xtrabackup \
  --prepare \
  --apply-log-only \
  --target-dir=/sql_backup/full \
  --incremental-dir=/sql_backup/inc1
```

### Step 3: Apply Second Incremental Backup (if any)

```bash
xtrabackup \
  --prepare \
  --apply-log-only \
  --target-dir=/sql_backup/full \
  --incremental-dir=/sql_backup/inc2
```

### Step 4: Finalize Full Backup

```bash
xtrabackup \
  --prepare \
  --target-dir=/sql_backup/full \
  --datadir=/home/radin/mysql/mysql_data2
```

---

## 6. Restore Backup

### Step 1: Stop MySQL

```bash
sudo systemctl stop mysql
```

### Step 2: Copy Back the Backup

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

---

# Docker-Based Backup and Restore

## Full Backup

```bash
docker run --rm -u 0 \
  -v mysql_data:/var/lib/mysql \
  -v /opt/mysql-backups:/backups \
  -v mysql_sock:/var/run/mysqld/ \
  percona/percona-xtrabackup:8.0 \
  xtrabackup --backup --user=root --password=123 --target-dir=/backups/full
```

---

## Prepare Full Backup

```bash
docker run --rm -u 0 \
  -v mysql_data:/var/lib/mysql \
  -v /opt/mysql-backups:/backups \
  -v mysql_sock:/var/run/mysqld/ \
  percona/percona-xtrabackup:8.0 \
  xtrabackup --prepare --target-dir=/backups/full
```

---

## Incremental Backup

```bash
docker run --rm -u 0 \
  -v mysql_data:/var/lib/mysql \
  -v /opt/mysql-backups:/backups \
  -v mysql_sock:/var/run/mysqld/ \
  percona/percona-xtrabackup:8.0 \
  xtrabackup \
    --backup \
    --user=root \
    --password=123 \
    --target-dir=/backups/inc1 \
    --incremental-basedir=/backups/full
```

---

## Apply Logs on Full Backup (Before Incrementals)

```bash
docker run --rm -u 0 \
  -v mysql_data:/var/lib/mysql \
  -v /opt/mysql-backups:/backups \
  -v mysql_sock:/var/run/mysqld/ \
  percona/percona-xtrabackup:8.0 \
  xtrabackup --prepare --apply-log-only --target-dir=/backups/full
```

---

## Merge Incremental with Full Backup

```bash
docker run --rm -u 0 \
  -v mysql_data:/var/lib/mysql \
  -v /opt/mysql-backups:/backups \
  -v mysql_sock:/var/run/mysqld/ \
  percona/percona-xtrabackup:8.0 \
  xtrabackup \
    --prepare \
    --apply-log-only \
    --target-dir=/backups/full \
    --incremental-dir=/backups/inc1
```

---

## Finalize Backup

```bash
docker run --rm -u 0 \
  -v mysql_data:/var/lib/mysql \
  -v /opt/mysql-backups:/backups \
  -v mysql_sock:/var/run/mysqld/ \
  percona/percona-xtrabackup:8.0 \
  xtrabackup --prepare --target-dir=/backups/full
```

---

## Reset MySQL Data Volume

```bash
docker stop mysql
docker volume rm mysql_data
docker volume create mysql_data
```

---

## Restore Backup

```bash
docker run --rm -u 0 \
  -v mysql_data:/var/lib/mysql \
  -v /opt/mysql-backups:/backups \
  percona/percona-xtrabackup:8.0 \
  xtrabackup --copy-back --target-dir=/backups/full --datadir=/var/lib/mysql
```

---

## Start MySQL

```bash
docker start mysql
```
