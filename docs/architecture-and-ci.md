# 部署仓库边界与 CI

TXBoard-Deploy 与 [TXBoard 主仓库](https://github.com/ANRCM0/TXBoard) 解耦。发布脚本与镜像的可见性不能代替依赖、权限及生产环境审计。

## 与 TXBoard 的边界

```text
TXBoard
  └── application image

TXBoard-Deploy
  ├── install.sh
  ├── txboard.sh
  ├── update.sh
  ├── gateway/deploy.sh
  └── node/deploy.sh
```

Deploy 仓库只依赖以下稳定运行接口：

- TXBoard image
- `/api/health`
- `php artisan txboard:install`
- `php artisan txboard:install-status`

部署逻辑不应该依赖 TXBoard 源码目录结构。

统一入口通过 `--component core|gateway|node` 选择组件，默认 Core。Gateway/Node 委托自包含脚本，分别使用 `txboard-gateway`/`tx-node` 预构建镜像；Core 新默认镜像为 `txboard-core`，旧 `txboard` 保存配置仍兼容。详情见 [三组件安装](components.md)。

新增 [持久升级影子演练](durable-upgrade.md) 使用固定的 B1 Core CLI 与 migration ID，仅适配已声明的 `subscription-shadow/v1` 版本组合。未知命令、生产 authority 切换和集群模式会拒绝；这不是旧镜像通用迁移接口。

## CI

本仓库 CI 验证：

- Bash 语法（install / update / manager）
- 三组件 literal 参数透传、实际文件 materialization 与旧 Core/Node 入口兼容
- Gateway 合成 Docker 生命周期、失败回滚/恢复、归属、锁及私密配置
- 合并后的 Node Installer 五套原 shell 回归（不执行 Node binary）
- 非交互 render-only 安装
- 内置 / 宿主机 Docker / 外部数据库 Compose 渲染
- 宿主机 MySQL 自动建库、建用户与 `txboard-db-link` 网络接入
- 残留内置 MySQL 数据卷的安全拒绝逻辑
- 完整 smoke install 后的管理命令与快捷子命令可用性
- 外部数据库探测和手动备份容器显式禁用 TTY，兼容 pipe / CI / 无交互输入
- 生成的 Compose 配置
- 生成的 Compose 不包含 `build:`
- 新 Core 默认镜像渲染断言，与已发布固定历史 Core 镜像的匿名 manifest 检查分开（新 `latest` 未发布时不假设可用）
- 签名 Manifest、真实 SQLite intent/cursor、子进程 kill 恢复、单调 fence、恢复备份边界和管理入口互锁
