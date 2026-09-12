# 使用说明

## 交互模式

运行：

```bash
kk
```

菜单：

```text
1. 列出 WordPress 站点
2. 备份单个站点
3. 恢复单个站点
4. 查看备份文件
5. 删除旧备份
6. 更新脚本
7. 快照管理
0. 退出
```

每一级菜单都支持 `0` 返回上一级。输错编号或域名格式错误时，脚本会提示并停留在当前流程。

## 快照管理

主菜单输入 `7`：

```text
1. 创建完整快照
2. 查看快照
3. 恢复完整快照
4. 删除快照
0. 返回上一级
```

完整快照采用 `域名_snapshot_年月日_时分秒.tar.gz` 命名，默认位于 `/home`。
包含站点文件、数据库、对应 Nginx 配置和证书，并记录原始文件权限。
创建快照只读取当前站点，不执行恢复。

恢复列表列出各域名的完整快照、文件大小及时间，按编号选择后输入 `yes` 确认。
即使站点目录已经不存在，也可以从列表中恢复。
恢复前默认创建当前站点的完整快照；创建失败就停止，不继续覆盖。
恢复快照时也采用同样的保护流程，不会递归执行恢复。

查看和删除列表会标注旧版 `before_restore` 文件；它们不能出现在完整快照恢复列表中。
删除需要输入 `yes` 确认。同一秒出现同名快照时会拒绝覆盖，请稍后重试。

快捷命令：

```bash
kk snapshot example.com
kk list-snapshots example.com
kk restore-snapshot example.com
kk restore-snapshot /home/example.com_snapshot_20260912_163233.tar.gz
```

`kk list-backups` 只列普通备份；菜单“查看备份文件”会列出普通备份、完整快照和旧版文件快照，并区分类型。

## 命令行模式

列出站点：

```bash
kk list
```

备份站点：

```bash
kk backup example.com
```

列出备份：

```bash
kk list-backups
kk list-backups example.com
```

恢复站点：

```bash
kk restore example.com
```

恢复指定压缩包：

```bash
kk restore /home/example.com_20260912_153000.tar.gz
```

## 备份文件名

备份文件会默认保存在 `/home`：

```text
example.com_20260912_153000.tar.gz
```

格式是：

```text
域名_年月日_时分秒.tar.gz
```
