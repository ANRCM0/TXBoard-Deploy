# TXBoard-Deploy 文档维护规范

`README.md` 负责说明本项目是什么、快速安装路径与各专题导航。所有需要随脚本变化的选项、菜单、数据库迁移行为统一维护在对应的 `docs/*.md` 中，而不是复制到 README 多处。

## 权威来源

- **命令与参数**：实际 `install.sh`、`update.sh`、`txboard.sh` 与相关 `lib/`。
- **安装/配置选项**：[installation.md](installation.md) 与 [unattended-install.md](unattended-install.md)。
- **服务发现、备份、恢复、升级**：[operations.md](operations.md)。
- **历史 XBoard 数据迁移**：[migration-from-xboard.md](migration-from-xboard.md)；必须保留隔离目标库与原生产库不修改的警告。
- **内置 MCP**：[mcp-gateway.md](mcp-gateway.md)；不要混淆独立 TXBoard-Gateway 用户 API BFF。
- **TXBoard 应用协议**：以 [主应用合同](https://github.com/ANRCM0/TXBoard/blob/main/contracts/README.md) 为准。

## 修改流程

1. 更新脚本时同步相应专题，列明前提、风险、备份与故障恢复。
2. 从 `txboard.sh` 的实际菜单与帮助输出核对编号、子命令和参数，不复制固定菜单到多个页面。
3. 使用 Current / Experimental / Target / Historical 区分运行中的行为、开关功能、未来方案和旧迁移记录。
4. Markdown 每页一个 H1；本仓库内使用相对链接，跨仓使用完整 URL。
5. 执行 `node scripts/check-docs.mjs` 检查本仓库文档的相对文件链接。外部网址、标题锚点和代码块内命令需要人工检查。

**不要把 CI 运行通过、脚本正确渲染或镜像可下载当作真实生产迁移/支付/节点接入验收的证明。**