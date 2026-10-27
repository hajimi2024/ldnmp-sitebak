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
original_run_wp_cli="$(declare -f run_wp_cli)"
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
! grep -Fq 'WordPress 收尾完成' "$fixture/wp-failure"
wp_fail_pattern=''

# 与 WP Box 共用固定镜像、网络及一次性容器；模拟首次拉取和缓存复用。
eval "$original_run_wp_cli"
[[ "$WPCLI_IMAGE" == 'wordpress:cli-2.12.0-php8.3@sha256:2b5e9d4d3e51909dca1aaa4732e9f5e5bf0377c2114dbd8ff39f060bff202586' ]]
[[ "$WPCLI_NETWORK" == web_default ]]
root="$fixture/target.example/wordpress"
mkdir -p "$root"
DB_HOST=mysql
DB_USER=target_user
DB_PASSWORD=target_password
DB_NAME=target_db
docker_calls="$fixture/docker-calls"
: > "$docker_calls"
image_cached=no
docker_fail=''
mock_owner=82:82
docker() {
  printf '%s ' "$@" >> "$docker_calls"
  printf '\n' >> "$docker_calls"
  case " $* " in
    *' network inspect web_default '*) return 0 ;;
    *' image inspect '*) [[ "$image_cached" == yes ]] ;;
    *' pull '*) [[ "$docker_fail" != pull ]] || return 1; image_cached=yes ;;
    *' run '*)
      [[ "$docker_fail" != run ]] || return 1
      case " $* " in
        *' --entrypoint php '*) [[ "$docker_fail" != db ]] ;;
        *" $WPCLI_IMAGE wp cli version "*) printf 'WP-CLI 2.12.0\n' ;;
        *" $WPCLI_IMAGE wp --info "*) printf 'PHP version:\t8.3.0\n' ;;
        *" $WPCLI_IMAGE cli "*|*" $WPCLI_IMAGE --info "*) return 127 ;;
        *) : ;;
      esac
      ;;
    *) return 1 ;;
  esac
}
stat() {
  if [[ "${1:-}" == -c && "${2:-}" == %u:%g ]]; then
    printf '%s\n' "$mock_owner"
  else
    command stat "$@"
  fi
}
prepare_wp_cli_environment "$root" > "$fixture/pull-output"
[[ "$image_cached" == yes ]]
grep -Fq '正在拉取并缓存' "$fixture/pull-output"
grep -Fq -- '--network web_default' "$docker_calls"
grep -Fq -- '--user 82:82' "$docker_calls"
grep -Fq -- '--cap-drop ALL' "$docker_calls"
grep -Fq -- '--security-opt no-new-privileges' "$docker_calls"
grep -Fq -- '--read-only' "$docker_calls"
grep -Fq -- '--tmpfs /tmp:rw,noexec,nosuid,size=64m' "$docker_calls"
grep -Fq -- '--entrypoint php' "$docker_calls"
grep -Fq -- "$WPCLI_IMAGE wp cli version" "$docker_calls"
grep -Fq -- "$WPCLI_IMAGE wp --info" "$docker_calls"
! grep -Fq -- "$WPCLI_IMAGE cli version" "$docker_calls"
grep -Fq -- '--mount type=bind,source=' "$docker_calls"
grep -Fq -- ',target=/var/www/html' "$docker_calls"
! grep -Eq ' exec | cp |curl|phar' "$docker_calls"
! grep -Fq 'target_password' "$docker_calls"
[[ $(grep -c '^pull ' "$docker_calls") == 1 ]]
: > "$docker_calls"
prepare_wp_cli_environment "$root" > "$fixture/reuse-output"
grep -Fq '已缓存' "$fixture/reuse-output"
! grep -Fq ' pull ' "$docker_calls"
run_wp_cli core is-installed
run_wp_cli elementor flush_css --regenerate
grep -Fq -- "$WPCLI_IMAGE wp --path=/var/www/html core is-installed" "$docker_calls"
grep -Fq -- "$WPCLI_IMAGE wp --path=/var/www/html elementor flush_css --regenerate" "$docker_calls"
[[ "$image_cached" == yes ]]

# 拉取失败、容器启动失败、数据库连接失败均在写入前中止。
image_cached=no
docker_fail=pull
if prepare_wp_cli_environment "$root" > "$fixture/pull-fail" 2>&1; then exit 1; fi
grep -Fq '镜像拉取失败' "$fixture/pull-fail"
docker_fail=run
image_cached=yes
if prepare_wp_cli_environment "$root" > "$fixture/run-fail" 2>&1; then exit 1; fi
grep -Fq '一次性容器无法启动' "$fixture/run-fail"
docker_fail=db
if prepare_wp_cli_environment "$root" > "$fixture/db-fail" 2>&1; then exit 1; fi
grep -Fq '无法通过目标凭据连接' "$fixture/db-fail"
docker_fail=''
WPCLI_TARGET_ROOT="$fixture/missing-site"
if run_wp_cli core is-installed > "$fixture/root-change-fail" 2>&1; then exit 1; fi
grep -Fq '目标 WordPress Root 无法验证' "$fixture/root-change-fail"
mock_owner=0:0
if prepare_wp_cli_environment "$root" > "$fixture/root-owner-fail" 2>&1; then exit 1; fi
grep -Fq '必须是非 root 用户' "$fixture/root-owner-fail"

# 菜单测试负责锁定当前三个入口；本文件只验证完整导入中的收尾步骤。
! declare -F cleanup_wp_cli_environment >/dev/null
printf 'PASS: URL, GUID, Elementor, WP Box image, cached pull and isolated container\n'
