# 安装说明

## 从旧命令迁移

v0.1.2 起，快捷命令为 `kk`。已安装旧版的用户也请执行下方安装命令一次，
将新版安装到 `/usr/local/bin/kk`，之后使用 `kk` 进入菜单、`kk update` 更新。
旧版的 `sitebak update` 会写入旧路径，不能直接完成首次命令迁移。
备份文件的位置和格式不变，无需移动或重新备份。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh -o /usr/local/bin/kk && chmod +x /usr/local/bin/kk
```

安装后运行：

```bash
kk
```

## 更新

```bash
kk update
```

或者在交互菜单中选择：

```text
6. 更新脚本
```

## 卸载

```bash
rm -f /usr/local/bin/kk
```

## 环境变量

可以通过环境变量覆盖默认路径：

```bash
SITEBAK_WEB_ROOT=/home/web kk
SITEBAK_SITE_ROOT=/home/web/html kk
SITEBAK_BACKUP_DIR=/home kk
```

默认 GitHub 更新地址：

```bash
SITEBAK_UPDATE_URL=https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh
```
