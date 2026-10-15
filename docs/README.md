# TXBoard Deploy 文档中心

本仓库负责 **安装、更新、备份、恢复、运维**，而不是 TXBoard 业务应用或 TX-Node 数据平面的开发。

| 文档 | 内容 |
| --- | --- |
| [安装指南](installation.md) | 首次安装、访问方式、数据库模式、安装器目录安全保护与镜像结构 |
| [三组件安装](components.md) | Core/Gateway/Node 统一入口、独立 Gateway 生命周期与旧 txnode 兼容 |
| [XBoard 数据迁入](migration-from-xboard.md) | 独立目标库、备份、历史数据库兼容、旧插件表审查 |
| [运维与升级](operations.md) | `txboard` 菜单、配置、备份、更新、恢复和数据安全红线 |
| [持久升级影子演练](durable-upgrade.md) | 签名 Manifest、持久 intent/probe、单机隔离副本回填对账与恢复边界 |
| [无人值守安装](unattended-install.md) | 自动化参数、模式限制及 CI/脚本使用 |
| [边界与 CI](architecture-and-ci.md) | 镜像分发、源码边界、自动检查事项 |

**文档维护原则**：脚本是命令与选项的最终来源；不要再把详细安装、迁移和日常运维全文堆回根 README。新选项必须同步更新对应章节，涉及破坏性行为的选项应写明前置检查、备份及恢复限制。

跨组件升级编排参考 [Core First v2](https://github.com/ANRCM0/TXBoard/blob/main/docs/architecture/v2/README.md) 和 [Upgrade Manifest v1](https://github.com/ANRCM0/TXBoard/blob/main/contracts/v2/upgrade-manifest/README.md)。`scripts/upgrade.py` 提供单机 `subscription-shadow/v1` 的 `plan/check/apply/status/recover/restore-check`；生产切换与集群恢复仍为 Target/Draft。具体执行范围与证据见 [影子演练](durable-upgrade.md)，现有安装、更新、备份命令以脚本为准。

[TXBoard 主应用](https://github.com/ANRCM0/TXBoard) · [主仓库文档中心](https://github.com/ANRCM0/TXBoard/blob/main/docs/README.md) · [原生数据库边界](https://github.com/ANRCM0/TXBoard/blob/main/docs/operations/native-schema.md)。

## Agent/MCP 退役记录

安装器不再启用 MCP；旧参数在服务发现前拒绝。隔离回归与历史镜像验收范围见 [退役验证](agent-retirement-verification.json)。

## 开发与集中验收

2026-10-15 用户确认：完成一个完整功能或多个相关阶段后统一测试、集中修复，再按批次提交推送。实现期间只做必要检查，纯文档不运行应用全量测试；复杂恢复与协议矩阵集中到发布验收或相关逻辑变更时。权限、凭据、数据写入/删除及覆盖恢复保留必要的针对性检查。具体约束见[AGENTS.md](../AGENTS.md)。

Node完整备份恢复批次已收尾；下一批优先基础安装、启动和正常更新。VMess恢复组合不另开独立批次；真实Core/TLS/有限授权、VMess恢复及安装更新失败回滚的剩余证据仍按关联批次或发布验收补齐。
