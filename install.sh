#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_PATH="${SITEBAK_INSTALL_PATH:-/usr/local/bin/kk}"
DOWNLOAD_URL="${SITEBAK_UPDATE_URL:-https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh}"
REQUEST_URL="$DOWNLOAD_URL"
if [[ "$REQUEST_URL" == https://raw.githubusercontent.com/* ]]; then
  separator='?'
  [[ "$REQUEST_URL" != *\?* ]] || separator='&'
  REQUEST_URL="${REQUEST_URL}${separator}sitebak_nocache=$(date +%s)"
fi
download=''
staged=''
YELLOW=''
RESET=''
if [[ ${TERM:-} != dumb && -z ${NO_COLOR+x} ]] && [[ -t 1 || -t 2 ]]; then
  YELLOW=$'\033[1;33m'
  RESET=$'\033[0m'
fi

finish() {
  local status=$?
  trap - EXIT
  [[ -z "$download" ]] || rm -f -- "$download"
  [[ -z "$staged" ]] || rm -f -- "$staged"
  if ((status == 0)); then
    printf '\n%s安装成功，输入 kk 进入菜单。%s\n' "$YELLOW" "$RESET"
  else
    printf '\n%s安装失败，请查看上方报错。%s\n' "$YELLOW" "$RESET" >&2
  fi
  exit "$status"
}
trap finish EXIT

if ((EUID != 0)); then
  printf '请使用 root 用户安装。\n' >&2
  exit 1
fi

for dependency in curl bash grep date mktemp install mv rm; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf '缺少安装所需命令：%s\n' "$dependency" >&2
    exit 1
  }
done

download="$(mktemp)"
curl -fsSL --connect-timeout 15 --max-time 120 "$REQUEST_URL" -o "$download"
if [[ ! -s "$download" ]] || ! bash -n "$download" || ! grep -q '^APP_NAME="LDNMP 单站备份恢复工具"$' "$download"; then
  printf '下载内容无效，安装已停止。\n' >&2
  exit 1
fi

# Replace the installed command only after download and validation succeed.
staged="$(mktemp "${INSTALL_PATH}.XXXXXX")"
install -m 0755 "$download" "$staged"
mv -f -- "$staged" "$INSTALL_PATH"
[[ -x "$INSTALL_PATH" ]]
