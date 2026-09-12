# 数据库客户端

v0.1.4 起，备份和恢复会读取所选站点 `wp-config.php` 中的数据库配置。
LDNMP 常见配置是 `DB_HOST=mysql`，脚本会自动使用同名、正在运行的 Docker 容器内的客户端。
宿主机不需要另装 MySQL，也不需要公开数据库端口。

支持 `mysqldump` / `mariadb-dump` 导出和 `mysql` / `mariadb` 导入。
不使用容器的站点使用宿主机客户端。支持 `主机:端口`，当前不支持 IPv6 或 Unix socket 格式的 `DB_HOST`。

容器名与 `DB_HOST` 不同时，显式指定数据库所在的容器：

```bash
SITEBAK_DB_CONTAINER=my-database kk
```

该变量表示数据库服务器本身所在的容器。脚本会在容器内通过 TCP 连接 `127.0.0.1` 和配置的端口。
不会猜测其他容器、创建容器、安装软件或修改数据库用户权限。
若容器缺失、未运行、工具缺失或数据库拒绝连接，显示错误后输入 `0` 返回菜单。

导出使用站点自己的数据库账号，密码通过环境变量传递，不放在命令参数或日志中。
使用 `--no-tablespaces`；MySQL 导出还设置 `--set-gtid-purged=OFF`，MariaDB 不使用这个 MySQL 专用参数。
数据库账号仍需具备读取对应站点表、视图、触发器等实际对象的权限。

v0.1.5 会通过客户端帮助信息探测 `masking_policies` 选项。支持时传入
`--masking_policies=OFF`，跳过服务器级脱敏策略的额外读取；旧版 MySQL 和 MariaDB 不会收到不支持的参数。
这适用于未使用数据库动态脱敏策略的普通 WordPress 站点。依赖这些策略的站点不在此备份模式的支持范围内。
该设置只影响本次导出，不关闭数据库服务器上的脱敏功能，不修改用户权限。

脚本同时保留并检查导出的错误输出，识别到 Error/Fatal 等错误时会停止打包，即使工具退出码是 0。
一般警告仍会显示，并随成功备份保存到 `meta/database-stderr.log`，不会一概隐藏。

数据库导出失败会清理临时文件；最终压缩包完成后才以“域名_时间戳.tar.gz”命名。
恢复会先从备份提取配置、检查 SQL 压缩文件和数据库连接，再询问覆盖确认。
新 VPS 的数据库账号、数据库权限和 LDNMP 服务仍需已就绪，本次修复不提供新环境的数据库用户重建。

本地验证：

```bash
bash -n sitebak.sh
bash tests/discovery.sh
bash tests/menu-failures.sh
bash tests/database-backend.sh
```

数据库测试使用模拟命令，不连接真实数据库；覆盖客户端选择、MariaDB 命令兼容、密码不进入参数、导出失败不生成备份、实际文件打包以及恢复连接失败不覆盖文件。

实现参考：[LDNMP 上游源码](https://github.com/kejilion/sh/blob/main/kejilion.sh)、[Docker exec](https://docs.docker.com/reference/cli/docker/container/exec/)、[MySQL mysqldump](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html)。
