#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../sitebak.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
SITE_ROOT="$fixture/html"
BACKUP_DIR="$fixture/backups"
NGINX_CONF_DIRS=()
CERT_DIRS=()
clear_screen() { :; }
reload_services() { :; }
chown() { :; }
DB_HOST=mysql
DB_USER=fixture_user
DB_PASSWORD='fixture secret $ with spaces'
MOCK_STATE=true
MOCK_DUMP=mysqldump
MOCK_CLIENT=mysql
MOCK_DUMP_STATUS=0
MOCK_CONNECT_STATUS=0
MOCK_VERSION=MySQL
docker() {
  if [[ $1 == inspect ]]; then
    [[ ${@: -1} == mysql || ${@: -1} == custom-db ]] || return 1
    printf '%s\n' "$MOCK_STATE"
    return 0
  fi
  [[ $1 == exec ]] || return 90
  shift
  if [[ ${2:-} == sh ]]; then
    [[ ${@: -1} == "$MOCK_DUMP" || ${@: -1} == "$MOCK_CLIENT" ]]
    return
  fi
  printf '%s\n' "$@" >> "$fixture/args"
  [[ "$MYSQL_PWD" == 'fixture secret $ with spaces' ]] || return 91
  [[ ${1:-} != -i ]] || shift
  [[ $1 == -e && $2 == MYSQL_PWD ]] || return 92
  shift 2
  [[ $1 == mysql || $1 == custom-db ]] || return 93
  shift
  if [[ " $* " == *' --version '* ]]; then
    printf '%s\n' "$MOCK_VERSION"
    return 0
  fi
  case "$1" in
    mysqldump|mariadb-dump)
      printf 'CREATE TABLE fixture_table (id int);\n'
      return "$MOCK_DUMP_STATUS"
      ;;
    mysql|mariadb)
      if [[ " $* " == *' -e '* ]]; then return "$MOCK_CONNECT_STATUS"; fi
      cat > "$fixture/imported.sql"
      ;;
    *) return 94 ;;
  esac
}
expect_failure() {
  local status
  set +e
  (set -Eeuo pipefail; "$@") > "$fixture/failure.log" 2>&1
  status=$?
  set -e
  [[ $status != 0 ]]
}
prepare_db_client dump
[[ $DB_CONTAINER == mysql && $DB_CLIENT == mysqldump ]]
run_mysqldump fixture_db > "$fixture/dump.sql"
grep -q -- '--set-gtid-purged=OFF' "$fixture/args"
grep -q -- '--no-tablespaces' "$fixture/args"
! grep -qF "$DB_PASSWORD" "$fixture/args"
MOCK_VERSION=MariaDB
: > "$fixture/args"
run_mysqldump fixture_db > "$fixture/maria-alias.sql"
! grep -q -- '--set-gtid-purged' "$fixture/args"
MOCK_VERSION=MySQL
MOCK_DUMP=mariadb-dump
MOCK_CLIENT=mariadb
prepare_db_client dump
[[ $DB_CLIENT == mariadb-dump ]]
: > "$fixture/args"
run_mysqldump fixture_db > "$fixture/maria.sql"
! grep -q -- '--set-gtid-purged' "$fixture/args"
prepare_db_client mysql
printf 'SELECT 1;\n' | run_mysql fixture_db
grep -qx -- '-i' "$fixture/args"
grep -q 'SELECT 1;' "$fixture/imported.sql"
DB_HOST=mysql:3307
prepare_db_client mysql
[[ " ${DB_CONNECT_ARGS[*]} " == *' -P 3307 '* ]]
SITEBAK_DB_CONTAINER=custom-db
prepare_db_client mysql
[[ $DB_CONTAINER == custom-db ]]
unset SITEBAK_DB_CONTAINER
DB_HOST=mysql
MOCK_STATE=false
expect_failure prepare_db_client dump
MOCK_STATE=true
MOCK_DUMP=missing
expect_failure prepare_db_client dump
MOCK_DUMP=mysqldump
MOCK_CLIENT=mysql
mkdir -p "$SITE_ROOT/example.com/wordpress" "$BACKUP_DIR"
printf "<?php\ndefine('DB_NAME', 'fixture_db');\ndefine('DB_USER', 'fixture_user');\ndefine('DB_PASSWORD', 'fixture secret \$ with spaces');\ndefine('DB_HOST', 'mysql');\n" > "$SITE_ROOT/example.com/wordpress/wp-config.php"
printf 'site content\n' > "$SITE_ROOT/example.com/wordpress/index.php"
MOCK_DUMP_STATUS=2
expect_failure backup_site example.com
[[ -z $(find "$BACKUP_DIR" -type f -print -quit) ]]
! grep -q '备份完成' "$fixture/failure.log"
MOCK_DUMP_STATUS=0
backup_site example.com > "$fixture/backup.log"
mapfile -t archives < <(list_backups_for_domain example.com)
[[ ${#archives[@]} == 1 ]]
[[ $(stat -c %a "${archives[0]}") == 600 ]]
mkdir "$fixture/extracted"
tar -xzf "${archives[0]}" -C "$fixture/extracted"
gzip -dc "$fixture/extracted/database/fixture_db.sql.gz" | grep -q 'CREATE TABLE'
tar -tzf "$fixture/extracted/files/site-files.tar.gz" | grep -q 'wordpress/wp-config.php'
printf 'current content\n' > "$SITE_ROOT/example.com/wordpress/index.php"
MOCK_CONNECT_STATUS=1
expect_failure restore_site "${archives[0]}"
[[ $(< "$SITE_ROOT/example.com/wordpress/index.php") == 'current content' ]]
MOCK_CONNECT_STATUS=0
restore_site "${archives[0]}" < <(printf 'yes\nn\n') > "$fixture/restore.log"
[[ $(< "$SITE_ROOT/example.com/wordpress/index.php") == 'site content' ]]
grep -q 'CREATE TABLE' "$fixture/imported.sql"
! grep -qF "$DB_PASSWORD" "$fixture/backup.log" "$fixture/restore.log" "$fixture/args"
unset -f docker
mysqldump() { printf 'native sql\n'; }
mysql() { cat; }
DB_HOST=127.0.0.1:3308
prepare_db_client dump
[[ -z $DB_CONTAINER && $DB_CLIENT == mysqldump ]]
[[ " ${DB_CONNECT_ARGS[*]} " == *' -P 3308 '* ]]
[[ $(run_mysqldump fixture_db) == 'native sql' ]]
DB_HOST=localhost
prepare_db_client mysql
[[ -z $DB_CONTAINER && $DB_CLIENT == mysql ]]
printf 'PASS: container/native clients, MariaDB fallback, ports, credentials, failed dump, archive and restore preflight\n'
