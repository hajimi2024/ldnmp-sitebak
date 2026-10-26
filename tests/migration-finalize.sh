#!/usr/bin/env bash
set -Eeuo pipefail
export NO_COLOR=1
source "$(dirname "$0")/../sitebak.sh"

fixture="$(mktemp -d)"
trap 'status=$?; if ((status != 0)); then find "$fixture" -maxdepth 1 -type f -print -exec sed -n "1,160p" {} \; >&2; fi; rm -rf -- "$fixture"' EXIT
MIGRATION_LOG_DIR="$fixture/logs"
MIGRATION_TMP_ROOT="$fixture/tmp"
SITE_ROOT="$fixture/html"
BACKUP_DIR="$fixture/backups"
mkdir -p "$MIGRATION_LOG_DIR" "$MIGRATION_TMP_ROOT" "$SITE_ROOT" "$BACKUP_DIR"
clear_screen() { :; }
get_target_server_display() { printf '%s' 'target-vps（2C / 4G）'; }

commands="$fixture/wp-commands"
old_home='http://old.example'
old_siteurl='https://old.example'
mock_current_home="$old_home"
mock_current_siteurl="$old_siteurl"
elementor_installed=yes
wp_fail_pattern=''
: > "$commands"

revalidate_migration_target_scope() { :; }
run_wp_cli() {
  printf '%q ' "$@" >> "$commands"
  printf '\n' >> "$commands"
  [[ -z "$wp_fail_pattern" || " $* " != *"$wp_fail_pattern"* ]] || return 71
  case " $* " in
    *' option get home '*) printf '%s\n' "$mock_current_home" ;;
    *' option get siteurl '*) printf '%s\n' "$mock_current_siteurl" ;;
    *' option update home '*) mock_current_home="${@: -1}" ;;
    *' option update siteurl '*) mock_current_siteurl="${@: -1}" ;;
    *' plugin is-installed elementor '*) [[ "$elementor_installed" == yes ]] ;;
    *' plugin is-active elementor '*) [[ "$elementor_installed" == yes ]] ;;
    *' plugin get elementor '*) printf '3.28.0\n' ;;
    *' plugin list '*'--status=must-use'*) : ;;
    *' plugin list '*) printf 'elementor\nelementor-pro\nwoocommerce\n' ;;
    *' config get table_prefix '*) printf 'source_\n' ;;
    *) : ;;
  esac
}

# 更换域名：四组映射都先 dry-run，再正式执行；始终跳过 GUID。
migration_log_init change-domain
MIGRATION_TARGET_DB_NAME=target_db
finalize_wordpress_migration change-domain old.example new.example https://new.example locked source_ > "$fixture/change-output" 2>&1
[[ "$mock_current_home" == https://new.example && "$mock_current_siteurl" == https://new.example ]]
[[ $(grep -c -- '--dry-run' "$commands") == 4 ]]
[[ $(grep -c -- '--skip-columns=guid' "$commands") == 8 ]]
[[ $(grep -c -- '--precise' "$commands") == 8 ]]
grep -Fq -- '--regex' "$commands"
grep -Fq 'elementor replace_urls' "$commands"
grep -Fq 'elementor flush_css --regenerate' "$commands"
grep -Fq 'rewrite flush' "$commands"
grep -Fq 'transient delete --all' "$commands"
! grep -Fq 'cache flush' "$commands"
grep -Fq '历史日志或授权记录' "$fixture/change-output"
grep -Fq 'GUID始终跳过' "$MIGRATION_LOG_FILE"

# 阶段四中途失败后，即使 home/siteurl 已是目标网址，精确映射仍可安全续跑。
: > "$commands"
finalize_wordpress_migration change-domain old.example new.example https://new.example locked source_ > "$fixture/change-resume-output" 2>&1
[[ $(grep -c -- '--dry-run' "$commands") == 4 ]]
grep -Fq 'WordPress 配置与数据库状态检查完成' "$fixture/change-resume-output"

# 保留域名且未安装 Elementor：不做全库替换，不因缺少 Elementor 失败。
: > "$commands"
old_home='http://same.example'
old_siteurl='http://same.example'
mock_current_home="$old_home"
mock_current_siteurl="$old_siteurl"
elementor_installed=no
migration_log_init keep-domain
finalize_wordpress_migration keep-domain same.example same.example https://same.example locked source_ > "$fixture/keep-output" 2>&1
! grep -Fq 'search-replace' "$commands"
! grep -Fq 'elementor replace_urls' "$commands"
grep -Fq '未安装 Elementor' "$fixture/keep-output"
[[ "$mock_current_home" == https://same.example && "$mock_current_siteurl" == https://same.example ]]

# WP-CLI 关键命令失败必须立即停止，不能输出完成状态。
: > "$commands"
old_home='http://old.example'
old_siteurl='http://old.example'
mock_current_home="$old_home"
mock_current_siteurl="$old_siteurl"
elementor_installed=no
wp_fail_pattern=' search-replace '
set +e
finalize_wordpress_migration change-domain old.example new.example https://new.example locked source_ > "$fixture/wp-failure" 2>&1
status=$?
set -e
[[ $status -ne 0 ]]
! grep -Fq '阶段四收尾完成' "$fixture/wp-failure"
wp_fail_pattern=''

# 宿主机路径只能映射到 PHP 容器实际挂载内。
mkdir -p "$fixture/mounted/example/wordpress" "$fixture/outside"
mock_wp_present=yes
docker() {
  case " $* " in
    *' inspect '*'{{.State.Running}}'*) printf 'true\n' ;;
    *' inspect '*'{{range .Mounts}}'*) printf '%s\t%s\n' "$fixture/mounted" /var/www/html ;;
    *' exec '*' command -v wp '*) [[ "$mock_wp_present" != yes ]] || printf '/usr/local/bin/wp\n'; return 0 ;;
    *' exec '*' echo PHP_VERSION'*) printf '8.5.12' ;;
    *' exec '*' cli version '*) printf 'WP-CLI 2.12.0\n' ;;
    *' exec '*) : ;;
    *' cp '*) : ;;
    *) return 1 ;;
  esac
}
[[ $(map_host_path_to_container php "$fixture/mounted/example/wordpress") == /var/www/html/example/wordpress ]]
set +e
map_host_path_to_container php "$fixture/outside" > "$fixture/outside-map" 2>&1
status=$?
set -e
[[ $status -ne 0 ]]
DB_HOST=mysql
DB_USER=target_user
DB_PASSWORD=target_password
DB_NAME=target_db
prepare_wp_cli_environment "$fixture/mounted/example/wordpress" "$fixture" 
[[ "$WPCLI_CONTAINER" == php && "$WPCLI_CONTAINER_ROOT" == /var/www/html/example/wordpress ]]
[[ "${WPCLI_COMMAND[*]}" == /usr/local/bin/wp ]]

# 容器没有 wp 时只准备固定版本、校验过的临时 Phar，并可清理。
mock_wp_present=no
curl() {
  local output=''
  while (($#)); do
    if [[ "$1" == -o ]]; then output="$2"; break; fi
    shift
  done
  printf 'mock wp-cli phar\n' > "$output"
}
WPCLI_SHA256="$(printf 'mock wp-cli phar\n' | sha256sum | awk '{print $1}')"
prepare_wp_cli_environment "$fixture/mounted/example/wordpress" "$fixture"
[[ "${WPCLI_COMMAND[0]}" == php && "${WPCLI_COMMAND[1]}" == /tmp/sitebak-wp-cli-* ]]
[[ -n "$WPCLI_TEMP_CONTAINER_PATH" ]]
cleanup_wp_cli_environment
[[ -z "$WPCLI_TEMP_CONTAINER_PATH" ]]

# 已有非空站点只有在存在可核验的阶段三完成日志和原始备份指纹时才可继续。
target_root="$SITE_ROOT/rovetree.com/wordpress"
mkdir -p "$target_root"
cat > "$target_root/wp-config.php" <<'EOF'
<?php
define('DB_NAME', 'rovetree_com');
define('DB_USER', 'target_user');
define('DB_PASSWORD', 'target_password');
define('DB_HOST', 'mysql');
$table_prefix = 'source_';
EOF
archive="$BACKUP_DIR/miniqq.shop_20261025_155627.tar.gz"
printf 'original backup evidence\n' > "$archive"
archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
record_log="$MIGRATION_LOG_DIR/migration_change-domain_20261025_160000.legacy.log"
cat > "$record_log" <<EOF
2026-10-25T16:00:00+08:00 [INFO] 已选择普通备份：${archive##*/}
2026-10-25T16:00:01+08:00 [INFO] 备份预检通过；源域名=miniqq.shop；源数据库=miniqq_shop；迁移表前缀=source_；备份指纹=$archive_sha
2026-10-25T16:00:02+08:00 [INFO] 目标预检通过；服务器=target-vps / machine:0123456789abcdef；用户=root；目标域名=rovetree.com；目标协议=https；目标属主=1000:1000；数据库=rovetree_com；目标身份=old-lock
2026-10-25T16:00:03+08:00 [INFO] 目标 WordPress Root 导入完成：$target_root
2026-10-25T16:00:04+08:00 [INFO] 阶段三写入状态；数据库已导入=yes；文件已替换=yes
EOF
[[ $(list_stage3_completion_records | wc -l) == 1 ]]

get_target_server_identity() { printf '%s' 'target-vps / machine:0123456789abcdef'; }
validate_migration_target_scope() {
  MIGRATION_TARGET_WP_ROOT="$(dirname "$2")"
}
prepare_db_client() {
  DB_CONTAINER=mysql
  DB_CLIENT=mysql
  DB_CONNECT_ARGS=(-h 127.0.0.1 --protocol=TCP -P 3306)
}
run_mysql() { :; }
detect_target_scheme() { printf 'https'; }
capture_migration_target_identity() {
  MIGRATION_TARGET_IDENTITY=current-lock
  MIGRATION_TARGET_SERVER='target-vps / machine:0123456789abcdef'
  MIGRATION_TARGET_SERVER_USERNAME=root
  MIGRATION_TARGET_DB_NAME="$DB_NAME"
}
prepare_wp_cli_environment() { migration_log INFO 'MOCK continue WP-CLI ready'; }
cleanup_wp_cli_environment() { :; }
finalize_wordpress_migration() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" > "$fixture/continued"
  migration_log INFO '阶段四收尾完成；MOCK'
}
continue_migration_finalize < <(printf '%s\n' 1 yes) > "$fixture/continue-output" 2>&1
[[ $(< "$fixture/continued") == 'change-domain|miniqq.shop|rovetree.com|https://rovetree.com' ]]
grep -Fq '站点域名替换与 WordPress 修复完成' "$fixture/continue-output"
[[ -z "$(list_stage3_completion_records)" ]]

rm -f -- "$record_log"
[[ -z "$(list_stage3_completion_records)" ]]

printf 'PASS: stage-four URL, GUID, Elementor, failure, container scope and legacy stage-three continuation\n'
