# 使用说明

## 交互模式

运行：

```bash
sitebak
```

菜单：

```text
1. 列出 WordPress 站点
2. 备份单个站点
3. 恢复单个站点
4. 查看备份文件
5. 删除旧备份
6. 更新脚本
0. 退出
```

每一级菜单都支持 `0` 返回上一级。输错编号或域名格式错误时，脚本会提示并停留在当前流程。

## 命令行模式

列出站点：

```bash
sitebak list
```

备份站点：

```bash
sitebak backup example.com
```

列出备份：

```bash
sitebak list-backups
sitebak list-backups example.com
```

恢复站点：

```bash
sitebak restore example.com
```

恢复指定压缩包：

```bash
sitebak restore /home/example.com_20260912_153000.tar.gz
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
