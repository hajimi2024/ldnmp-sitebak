# 安装说明

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh -o /usr/local/bin/sitebak && chmod +x /usr/local/bin/sitebak
```

安装后运行：

```bash
sitebak
```

## 更新

```bash
sitebak update
```

或者在交互菜单中选择：

```text
6. 更新脚本
```

## 卸载

```bash
rm -f /usr/local/bin/sitebak
```

## 环境变量

可以通过环境变量覆盖默认路径：

```bash
SITEBAK_WEB_ROOT=/home/web sitebak
SITEBAK_SITE_ROOT=/home/web/html sitebak
SITEBAK_BACKUP_DIR=/home sitebak
```

默认 GitHub 更新地址：

```bash
SITEBAK_UPDATE_URL=https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh
```
