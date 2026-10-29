#!/usr/bin/env bash
set -Eeuo pipefail
export NO_COLOR=1
source "$(dirname "$0")/../sitebak.sh"

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/source" "$fixture/target"
cat > "$fixture/source/wp-config.php" <<'PHP'
<?php
define('DB_NAME', 'source_db');
define('DB_USER', 'source_user');
define('DB_PASSWORD', 'source_secret');
define('DB_HOST', 'mysql');
$table_prefix = 'source_';
PHP
cat > "$fixture/target/wp-config.php" <<'PHP'
<?php
define('DB_NAME', 'target_db');
define('DB_USER', 'target_user');
define('DB_PASSWORD', 'target_secret');
define('DB_HOST', 'mysql');
$table_prefix = 'target_';
PHP

source_config="$fixture/source/wp-config.php"
target_config="$fixture/target/wp-config.php"
cp "$source_config" "$fixture/base-config"
cp "$target_config" "$fixture/target-before"

# 实测故障：源站写死旧域名，必须在暂存区改为目标网址，不能修改源站或目标站。
cat >> "$source_config" <<'PHP'
define('WP_HOME', 'https://old.example');
define("WP_SITEURL", "http://old.example"); // WP_HOME is checked separately
// define('WP_HOME', 'https://comment.example');
PHP
prepare_migration_stage "$fixture/source" "$target_config" "$fixture/stage-valid" old.example https://new.example
grep -Fq "define('WP_HOME', 'https://new.example');" "$fixture/stage-valid/wp-config.php"
grep -Fq "define('WP_SITEURL', 'https://new.example');" "$fixture/stage-valid/wp-config.php"
grep -Fq "// define('WP_HOME', 'https://comment.example');" "$fixture/stage-valid/wp-config.php"
grep -Fq "define('WP_HOME', 'https://old.example');" "$source_config"
cmp "$target_config" "$fixture/target-before"
[[ $(parse_migration_wp_define "$fixture/stage-valid/wp-config.php" DB_NAME) == target_db ]]
[[ $(parse_wp_table_prefix "$fixture/stage-valid/wp-config.php") == source_ ]]

# 保留域名但目标协议不同时，静态常量也必须跟随已验证的目标网址。
cp "$fixture/base-config" "$source_config"
printf "define('WP_HOME', 'http://same.example');\n" >> "$source_config"
prepare_migration_stage "$fixture/source" "$target_config" "$fixture/stage-keep" same.example https://same.example
grep -Fq "define('WP_HOME', 'https://same.example');" "$fixture/stage-keep/wp-config.php"

# 没有网址常量时不添加；动态、重复、其他域名及带路径常量均在目标写入前拒绝。
cp "$fixture/base-config" "$source_config"
prepare_migration_stage "$fixture/source" "$target_config" "$fixture/stage-absent" old.example https://new.example
! grep -Eq 'WP_HOME|WP_SITEURL' "$fixture/stage-absent/wp-config.php"

expect_rejection() {
  local name="$1" content="$2"
  cp "$fixture/base-config" "$source_config"
  printf '%s\n' "$content" >> "$source_config"
  if prepare_migration_stage "$fixture/source" "$target_config" "$fixture/stage-$name" old.example https://new.example > "$fixture/error-$name" 2>&1; then
    printf 'Unsafe URL constant accepted: %s\n' "$name" >&2
    exit 1
  fi
  grep -Fq '不能唯一安全适配目标网址' "$fixture/error-$name"
  cmp "$target_config" "$fixture/target-before"
}
expect_rejection dynamic "define('WP_HOME', 'https://' . \$_SERVER['HTTP_HOST']);"
expect_rejection other-domain "define('WP_HOME', 'https://other.example');"
expect_rejection path "define('WP_SITEURL', 'https://old.example/wordpress');"
expect_rejection duplicate $'define('\''WP_HOME'\'', '\''https://old.example'\'');\ndefine('\''WP_HOME'\'', '\''https://old.example'\'');'

printf 'PASS: staged URL constants adapt safely before import; ambiguous constants stop without target writes\n'
