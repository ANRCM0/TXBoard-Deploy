# 部署仓库边界与 CI

TXBoard-Deploy 与 [TXBoard 主仓库](https://github.com/ANRCM0/TXBoard) 解耦。发布脚本与镜像的可见性不能代替依赖、权限及生产环境审计。

## 与 TXBoard 的边界

```text
TXBoard
  └── application image

TXBoard-Deploy
  ├── install.sh
  ├── txboard.sh
  └── update.sh
```

Deploy 仓库只依赖以下稳定运行接口：

- TXBoard image
- `/api/health`
- `php artisan txboard:install`
- `php artisan txboard:install-status`

部署逻辑不应该依赖 TXBoard 源码目录结构。

## CI

本仓库 CI 验证：

- Bash 语法（install / update / manager）
- 非交互 render-only 安装
- 内置 / 宿主机 Docker / 外部数据库 Compose 渲染
- 宿主机 MySQL 自动建库、建用户与 `txboard-db-link` 网络接入
- 残留内置 MySQL 数据卷的安全拒绝逻辑
- 完整 smoke install 后的管理命令与快捷子命令可用性
- 外部数据库探测和手动备份容器显式禁用 TTY，兼容 pipe / CI / 无交互输入
- 生成的 Compose 配置
- 生成的 Compose 不包含 `build:`
- 默认 TXBoard 公共镜像 manifest 可被匿名读取
