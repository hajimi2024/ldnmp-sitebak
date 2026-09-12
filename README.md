# ldnmp-sitebak

`ldnmp-sitebak` 是一个面向 LDNMP/科技 LION 常见服务器结构的 WordPress 单站点备份恢复脚本。

它的目标很简单：当一台 VPS 上有多个 WordPress 站点时，不再只能把整个 `/home/web` 全站打成一个包，而是可以按域名单独备份、单独恢复。

## 功能

- 纯交互菜单，输入 `sitebak` 即可使用。
- 单独备份某个 WordPress 站点。
- 同一站点多个备份版本可按编号选择恢复。
- 备份包自带时间戳，例如 `example.com_20260912_153000.tar.gz`。
- 自动备份站点文件、数据库、Nginx 配置、SSL 证书和恢复清单。
- 恢复前二次确认，并可自动创建当前站点快照。
- 支持从 GitHub 更新本地脚本。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/sitebak.sh -o /usr/local/bin/sitebak && chmod +x /usr/local/bin/sitebak
```

## 使用

进入交互菜单：

```bash
sitebak
```

快捷备份：

```bash
sitebak backup example.com
```

恢复指定站点，并从备份列表中选择版本：

```bash
sitebak restore example.com
```

直接恢复指定备份包：

```bash
sitebak restore /home/example.com_20260912_153000.tar.gz
```

更新脚本：

```bash
sitebak update
```

## 默认路径

```bash
站点目录：/home/web/html
备份目录：/home
Nginx 配置：/home/web/conf.d
SSL 证书：/home/web/certs
```

如需覆盖默认路径，可以使用环境变量：

```bash
SITEBAK_BACKUP_DIR=/root/backups sitebak backup example.com
```

## 备份包内容

```text
files/site-files.tar.gz
database/数据库名.sql.gz
nginx/nginx-files.tar.gz
certs/cert-items.tar.gz
meta/
manifest.json
restore-notes.txt
```

## 注意事项

- 推荐在同样的 LDNMP 环境中恢复。
- 同域名恢复通常不需要额外修改 WordPress 设置。
- 如果更换域名，当前版本不会自动执行 WordPress 数据库 `search-replace`。
- 商业插件的文件、设置和数据库中的 license key 通常会被备份，但远程激活状态是否保持取决于插件厂商。

更多说明见 [安装文档](docs/INSTALL.md)、[使用文档](docs/USAGE.md) 和 [恢复说明](docs/RESTORE.md)。

## 开源协议

MIT License
