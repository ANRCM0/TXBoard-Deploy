# TXBoard Deploy 文档中心

本仓库负责 **安装、更新、备份、恢复、运维**，而不是 TXBoard 业务应用或 TX-Node 数据平面的开发。

| 文档 | 内容 |
| --- | --- |
| [安装指南](installation.md) | 首次安装、访问方式、数据库模式、安装器目录安全保护与镜像结构 |
| [XBoard 数据迁入](migration-from-xboard.md) | 独立目标库、备份、历史数据库兼容、旧插件表审查 |
| [运维与升级](operations.md) | `txboard` 菜单、配置、备份、更新、恢复和数据安全红线 |
| [内置 MCP Gateway](mcp-gateway.md) | 主应用镜像可选 MCP 开关与前置条件 |
| [无人值守安装](unattended-install.md) | 自动化参数、模式限制及 CI/脚本使用 |
| [边界与 CI](architecture-and-ci.md) | 镜像分发、源码边界、自动检查事项 |

**文档维护原则**：脚本是命令与选项的最终来源；不要再把详细安装、迁移和日常运维全文堆回根 README。新选项必须同步更新对应章节，涉及破坏性行为的选项应写明前置检查、备份及恢复限制。

下一轮升级编排参考 [Core First v2 B0](https://github.com/ANRCM0/TXBoard/blob/main/docs/architecture/v2/README.md) 和 [Upgrade Manifest v1](https://github.com/ANRCM0/TXBoard/blob/main/contracts/v2/upgrade-manifest/README.md)（Target/Draft）。拟议 `upgrade plan/check/apply/status/recover` 尚未实现；现有安装、更新、备份命令仍以本仓脚本为准。

[TXBoard 主应用](https://github.com/ANRCM0/TXBoard) · [主仓库文档中心](https://github.com/ANRCM0/TXBoard/blob/main/docs/README.md) · [原生数据库边界](https://github.com/ANRCM0/TXBoard/blob/main/docs/operations/native-schema.md)。
