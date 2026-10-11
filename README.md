# TXBoard Deploy

**TXBoard 的公开部署与服务器运维工具。** 通过预构建镜像安装、升级、备份及管理 TXBoard，不要求在目标服务器克隆 Laravel/React/Vue 源码、安装 Composer/npm 或自行构建主应用。

[TXBoard 主仓库](https://github.com/ANRCM0/TXBoard) · [部署详细指南](docs/README.md) · [升级与运维](docs/operations.md) · [迁移 XBoard](docs/migration-from-xboard.md)

> **高风险操作警告**：新安装目标必须是独立空数据库。不要把安装器指向现有生产 XBoard/TXBoard 数据库，也不要尝试通过常规升级器将旧 `v2_*` 表在线升级为 `tx_*`。已有部署必须先备份并验证恢复；旧数据库导入采用隔离目标库流程。

## 快速安装

支持 Linux amd64/arm64。需要访问 GitHub / GHCR、Docker Engine 与 Docker Compose v2；交互安装在受支持场景可协助安装 Docker。

```bash
# 建议先下载并检查公开安装脚本
curl -fL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

交互安装向导将引导选择镜像版本、管理员账户、数据库模式和 HTTPS/反向代理接入等参数。需要用管道方式执行时，见 [安装指南](docs/installation.md)，理解脚本的终端输入与安全保护。

## 部署模式

| 选项 | 支持方式 |
| --- | --- |
| 数据库 | 内置 MySQL、宿主机/1Panel Docker MySQL、外部 MySQL |
| 对外访问 | Caddy 自动 HTTPS、外部 HTTPS 反向代理、HTTP（仅适合受控环境） |
| MCP | 主 TXBoard 镜像内置的可选 MCP Gateway，默认关闭 |
| 运行镜像 | `ghcr.io/anrcm0/txboard`，正式生产建议固定已验收版本/digest |

**TXBoard-Deploy 不是 TX-Node 安装器**。节点请使用独立 [TX-Node-Installer](https://github.com/ANRCM0/TX-Node-Installer)。

## 安装后常用操作

```bash
sudo txboard             # 交互运维菜单
sudo txboard status      # 容器与安装状态
sudo txboard diagnose    # 诊断
sudo txboard backup      # 创建备份
sudo txboard update      # 安全更新（带预检和备份）
sudo txboard admin-reset-path  # 轮换管理后台安全路径
```

更新器会在符合条件的既有部署上做保护性检查，并不承诺能自动回滚已经修改过的数据库结构。完整菜单和限制见 [运维指南](docs/operations.md)。

## 按任务阅读文档

| 我要做什么 | 文档 |
| --- | --- |
| 第一次部署、数据库/反代模式选型 | [安装指南](docs/installation.md) |
| 已有 XBoard，需要迁移历史数据 | [隔离导入流程](docs/migration-from-xboard.md) |
| 已有 TXBoard，升级、备份、恢复、诊断 | [运维与升级](docs/operations.md) |
| 配置 AI Agent 的 MCP 接入 | [内置 MCP Gateway](docs/mcp-gateway.md) |
| CI、自动化安装与参数说明 | [无人值守安装](docs/unattended-install.md) |
| 部署层与应用仓库的职责边界 | [仓库边界与 CI](docs/architecture-and-ci.md) |

## 安全提示

- 所有数据库备份、`.env`、APP_KEY、支付令牌和私密日志必须限制访问，不能上传公开仓库。
- 不要运行 `docker compose down -v` 清理数据卷；不要跳过升级前的完整备份。
- 安装、更新、迁移前先核实真实运行的容器和 Compose 项目，**不根据容器名猜测归属**。
- 公开 Docker 镜像可以被拉取并检查文件系统，镜像公开不意味着其中源码具备保密性。
- CI/镜像发布不是生产验收；对数据迁移、支付、Node 和 Agent 的上线验证见 [主仓库发布 Runbook](https://github.com/ANRCM0/TXBoard/blob/main/docs/operations/release-staging-acceptance.md)。

本仓库只负责部署与服务器生命周期，不修改 TXBoard 的账本、权限和接口契约。