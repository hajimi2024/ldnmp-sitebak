# 任务书：LDNMP 单站点备份恢复脚本

## 项目目标

创建一个适配 LDNMP/科技 LION 常见目录结构的单站点 WordPress 备份恢复脚本，解决原有全站备份会把 `/home/web` 下所有站点一次性打包的问题。

脚本应支持“首次从 GitHub 安装到 VPS，本地快捷指令日常调用”的使用方式：

```bash
sitebak
```

## 核心能力

- 交互式菜单列出 WordPress 站点。
- 单独备份某一个域名对应的 WordPress 站点。
- 单独恢复某一个域名对应的备份版本。
- 同一站点存在多个备份时，按时间倒序展示并让用户选择。
- 支持命令行快捷操作。
- 支持从 GitHub 更新本地脚本。

## 备份内容

每个单站备份包应包含：

- WordPress 站点目录。
- 从 `wp-config.php` 读取到的数据库导出文件。
- 对应 Nginx 配置文件。
- 对应 SSL 证书文件或目录。
- `manifest.json` 备份清单。
- `restore-notes.txt` 恢复说明。

## 备份文件规则

默认备份目录：

```bash
/home
```

文件名格式：

```bash
域名_年月日_时分秒.tar.gz
```

示例：

```bash
example.com_20260912_153000.tar.gz
```

## 交互体验

脚本交互应参考 LDNMP 一键脚本的终端菜单风格：

- 编号菜单。
- 彩色状态提示。
- 每一级支持 `0` 返回上一级。
- 输入错误时提示并留在当前流程。
- 域名格式错误时提示重新输入或返回。

## 安全要求

- 源码不得写死服务器 IP、数据库密码、SSH 密钥、Token 或个人隐私信息。
- 恢复前必须要求用户输入 `yes` 二次确认。
- 覆盖当前站点前默认询问是否创建当前站点快照。
- 脚本应优先从本机 WordPress 配置读取数据库信息。

## 兼容目标

优先兼容以下路径：

```bash
/home/web/html
/home/web/conf.d
/home/web/certs
```

并兼容部分常见替代路径：

```bash
/home/web/nginx/conf.d
/etc/nginx/conf.d
/etc/nginx/sites-enabled
/etc/letsencrypt
```

## 开源交付物

- `sitebak.sh`
- `README.md`
- `docs/INSTALL.md`
- `docs/USAGE.md`
- `docs/RESTORE.md`
- `LICENSE`
- `.gitignore`
