#!/bin/bash
# Runs once, on MySQL's first boot, from /docker-entrypoint-initdb.d.
# Creates a least-privilege user for mysqld_exporter.
#
# PROCESS + REPLICATION CLIENT are what the exporter actually needs; SELECT is
# scoped to performance_schema only. Deliberately NOT the app user and
# definitely not root.
set -eu
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<SQL
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'exporter'@'%';
GRANT SELECT ON performance_schema.* TO 'exporter'@'%';
FLUSH PRIVILEGES;
SQL
echo "mysqld_exporter user created"
