#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_PATH="${SITEBAK_INSTALL_PATH:-/usr/local/bin/kk}"
DOWNLOAD_URL="${SITEBAK_UPDATE_URL:-https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh}"
REQUEST_URL="$DOWNLOAD_URL"
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

for dependency in curl bash grep date sed head mktemp install mv rm; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf '缺少安装所需命令：%s\n' "$dependency" >&2
    exit 1
  }
done

if [[ "$DOWNLOAD_URL" == 'https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh' ]]; then
  api_response="$(curl -fsSL --connect-timeout 15 --max-time 120 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/hajimi2024/ldnmp-sitebak/commits/main?sitebak_nocache=$(date +%s)")"
  latest_commit="$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)",[[:space:]]*$/\1/p' <<< "$api_response" | head -n 1)"
  if [[ ! "$latest_commit" =~ ^[0-9a-f]{40}$ ]]; then
    printf '无法确认 GitHub main 最新提交，安装已停止。\n' >&2
    exit 1
  fi
  REQUEST_URL="https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/${latest_commit}/sitebak.sh"
fi

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
