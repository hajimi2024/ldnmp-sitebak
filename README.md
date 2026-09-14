# ldnmp-sitebak

`ldnmp-sitebak` 是一个面向 LDNMP/科技 LION 常见服务器结构的 WordPress 单站点备份恢复脚本。

它的目标很简单：当一台 VPS 上有多个 WordPress 站点时，不再只能把整个 `/home/web` 全站打成一个包，而是可以按域名单独备份、单独恢复。

## 功能

- 纯交互菜单，输入 `kk` 即可使用。
- 单独备份某个 WordPress 站点。
- 同一站点多个备份版本可按编号选择恢复。
- 菜单 `4` 每次实时扫描当前 WordPress 站点；选定域名后，只显示该域名的普通备份版本。
- 备份包自带时间戳，例如 `example.com_20260912_153000.tar.gz`。
- 自动备份站点文件、数据库、Nginx 配置、SSL 证书和恢复清单。
- 恢复前二次确认，并可自动创建当前站点快照。
- 完整快照包含站点文件、数据库、Nginx 配置和证书，菜单 `5` 可创建、查看、恢复和删除快照。
- 普通备份与快照分别管理：菜单 `3/4/6` 只查看、恢复、删除普通备份，快照统一进入菜单 `5`。
- 固定五行 LDNMP 字符 Banner，中文副标题上下使用同宽分隔线；采用亮青蓝主色、黄色编号、草绿色标签和浅草绿色版本与目录信息，以及绿/红/黄状态提示。
- 支持从 GitHub 更新本地脚本。

## 安装

```bash
(set -o pipefail; curl -fsSL --connect-timeout 15 --max-time 120 https://raw.githubusercontent.com/hajimi2024/ldnmp-sitebak/main/install.sh | bash) && echo "安装成功，输入 kk 进入菜单。" || (echo "安装失败，请查看上方报错。" >&2; exit 1)
```

在 Linux VPS 的 root 终端执行。安装结束会明确显示成功或失败；下载或校验失败时保留已安装的脚本。

## 使用

进入交互菜单：

```bash
kk
```

快捷备份：

```bash
kk backup example.com
```

恢复指定站点，并从备份列表中选择版本：

```bash
kk restore example.com
```

直接恢复指定备份包：

```bash
kk restore /home/example.com_20260912_153000.tar.gz
```

更新脚本：

```bash
kk update
```

## 默认路径

站点识别支持 `/home/web/html/域名/wp-config.php` 和 LDNMP 常用的
`/home/web/html/域名/wordpress/wp-config.php`。备份仍打包整个域名目录，保留原目录结构。
若同一域名两处都存在配置，脚本不会自动选择，以免选错数据库。

```bash
站点目录：/home/web/html
备份目录：/home
Nginx 配置：/home/web/conf.d
SSL 证书：/home/web/certs
```

如需覆盖默认路径，可以使用环境变量：

```bash
SITEBAK_BACKUP_DIR=/root/backups kk backup example.com
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

- v0.2.8：版本、站点目录和备份目录的标签改为与菜单编号一致的加粗黄色；对应的版本号和路径仍为浅草绿色。

- v0.2.7：菜单 `4` 先实时扫描并选择当前 WordPress 站点，再按编号显示该域名的普通备份；选中没有备份的域名时提示“当前域名无可用备份”。

- v0.2.6：版本、站点目录和备份目录三行采用草绿色标签与浅草绿色值，取代原来的白色显示。

- v0.2.5：主菜单和快照管理的每组操作之间增加一行空白，形成约 2 倍行距；双列对齐、窄屏单列与实际功能编号不变。

- v0.2.4：普通备份与快照的查看、删除入口分开，文件选择页标明类型；采用已确认的 Banner、分界线和配色，覆盖主菜单、快照菜单、站点与文件选择页。设置 `NO_COLOR`、使用 `TERM=dumb` 或输出未连接终端时关闭颜色。备份文件名、内容和恢复前快照保护流程不变。

- v0.2.3：固定主菜单顺序为列出站点、备份站点、查看备份、恢复站点、快照管理、删除旧备份、更新脚本；菜单显示与实际功能编号同步调整，`0` 退出。备份和快照的筛选范围保持不变。

- v0.2.2：主菜单和快照管理采用 Kejilion 风格双列排版，单数编号后双空格、右列固定对齐、短分隔线；终端少于 58 列时自动改为单列。

- v0.2.0：快照升级为完整单站备份，命名为 `域名_snapshot_日期_时间.tar.gz`。恢复前选择创建快照时，快照失败会停止恢复。旧版 `before_restore` 文件只含网站文件，可查看、删除，不能完整恢复，也无法通过改名补齐数据库。

- v0.1.6：修复恢复后统一更改文件归属的问题，按备份保留每个站点文件的数字 UID/GID 和权限；兼容旧版备份。通过真实 Linux 文件权限测试，数据库和服务调用使用模拟命令。

- v0.1.5：检测客户端支持情况，关闭单站备份中的服务器级脱敏策略导出，避免普通站点账号触发 `column_masking_policy` 权限错误；导出工具即使返回成功码，若仍报告错误也会停止打包。此模式不适用于依赖数据库脱敏策略的站点。

- v0.1.4：支持 LDNMP 的数据库容器，宿主机无需单独安装 `mysqldump`；兼容容器内 MySQL/MariaDB 导出与导入工具。数据库导出失败不会生成备份包，恢复前先检查客户端和数据库连接。
- 自动匹配 `DB_HOST` 同名的 Docker 容器（LDNMP 通常为 `mysql`）。容器自定义名称与 `DB_HOST` 不一致时，可使用 `SITEBAK_DB_CONTAINER=容器名 kk`；不使用容器的站点继续使用宿主机客户端。
- 数据库兼容性已通过模拟 Docker/数据库命令的回归测试，包含实际文件打包和恢复；尚未在真实数据库服务器上完成端到端验证。

- v0.1.3：菜单操作失败后保留错误信息，输入 `0` 返回上一级；更新下载或校验失败时保留原脚本。

- v0.1.1 修复 LDNMP 的 `wordpress` 子目录识别、空站点列表和标题边框对齐。
- 本地回归测试覆盖站点识别、数据库配置读取、菜单输出及边框宽度；尚未完成真实 VPS 的备份恢复验证。

- 推荐在同样的 LDNMP 环境中恢复。
- 同域名恢复通常不需要额外修改 WordPress 设置。
- 如果更换域名，当前版本不会自动执行 WordPress 数据库 `search-replace`。
- 商业插件的文件、设置和数据库中的 license key 通常会被备份，但远程激活状态是否保持取决于插件厂商。

更多说明见 [安装文档](docs/INSTALL.md)、[使用文档](docs/USAGE.md)、[恢复说明](docs/RESTORE.md) 和 [数据库兼容性](docs/DATABASE.md)。

## 开源协议

MIT License
