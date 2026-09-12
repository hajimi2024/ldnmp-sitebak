#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_PATH="${SITEBAK_INSTALL_PATH:-/usr/local/bin/kk}"
DOWNLOAD_URL="${SITEBAK_UPDATE_URL:-https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh}"
download=''
staged=''
trap '[[ -z "$download" ]] || rm -f -- "$download"; [[ -z "$staged" ]] || rm -f -- "$staged"' EXIT

if ((EUID != 0)); then
  printf '请使用 root 用户安装。\n' >&2
  exit 1
fi

for dependency in curl bash grep mktemp install mv rm; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf '缺少安装所需命令：%s\n' "$dependency" >&2
    exit 1
  }
done

download="$(mktemp)"
curl -fsSL --connect-timeout 15 --max-time 120 "$DOWNLOAD_URL" -o "$download"
if [[ ! -s "$download" ]] || ! bash -n "$download" || ! grep -q '^APP_NAME="LDNMP 单站备份恢复工具"$' "$download"; then
  printf '下载内容无效，安装已停止。\n' >&2
  exit 1
fi

# Replace the installed command only after download and validation succeed.
staged="$(mktemp "${INSTALL_PATH}.XXXXXX")"
install -m 0755 "$download" "$staged"
mv -f -- "$staged" "$INSTALL_PATH"
[[ -x "$INSTALL_PATH" ]]
