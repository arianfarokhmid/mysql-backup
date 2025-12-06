CREATE USER 'inc_backuper'@'localhost' IDENTIFIED BY 'hzgGYXJb082P3JWTQ1suIw6dJAsl';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'inc_backuper'@'localhost';
GRANT SELECT ON performance_schema.log_status TO 'inc_backuper'@'localhost';
GRANT SELECT ON performance_schema.keyring_component_status TO inc_backuper@'localhost';
GRANT SELECT ON performance_schema.replication_group_members TO inc_backuper@'localhost';
FLUSH PRIVILEGES;