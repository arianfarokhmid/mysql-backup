CREATE USER 'bkpuser'@'172.%' IDENTIFIED BY 'jRhBEXFo2waHL23PlocT9szn3ZuN';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'bkpuser'@'172.%';
GRANT SELECT ON performance_schema.log_status TO 'bkpuser'@'172.%';
GRANT SELECT ON performance_schema.keyring_component_status TO bkpuser@'172.%';
GRANT SELECT ON performance_schema.replication_group_members TO bkpuser@'172.%';
FLUSH PRIVILEGES;