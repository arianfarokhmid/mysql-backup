CREATE USER 'inc_backuper'@'localhost' IDENTIFIED BY 'pass';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'inc_backuper'@'localhost';
GRANT SELECT ON performance_schema.log_status TO 'inc_backuper'@'localhost';
GRANT SELECT ON performance_schema.keyring_component_status TO inc_backuper@'localhost';
GRANT SELECT ON performance_schema.replication_group_members TO inc_backuper@'localhost';
FLUSH PRIVILEGES;
CREATE USER 'data_cheker'@'localhost' IDENTIFIED BY 'T39EEyFRCCfmeNeQNXMbXVrK';
GRANT SELECT ON azki_loan.ticket TO 'data_cheker'@'localhost';
FLUSH PRIVILEGES;