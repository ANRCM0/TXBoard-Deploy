# 部署内置 MCP Gateway

本页描述 TXBoard **主镜像内置的 MCP Agent Ops 适配器**，与独立 [TXBoard-Gateway](https://github.com/ANRCM0/TXBoard-Gateway) 用户主题 BFF 不同。MCP 不拥有独立的账本、管理员身份或 Node 控制平面。

## MCP Gateway

新版 TXBoard 主镜像已经内置 MCP Gateway，但默认关闭。交互安装时会询问：

```text
Enable MCP Gateway for AI Agents (Hermes / OpenClaw)? [N]:
```

启用后，部署文件写入：

```env
TXBOARD_ENABLE_MCP=true
```

TXBoard 仍然只暴露原有 HTTP/HTTPS 入口，MCP 通过同域路径提供：

```text
https://panel.example.com/mcp
```

MCP Node 进程只监听容器 loopback，不新增公网 3000 端口。Gateway 仍然只调用 TXBoard Agent Ops API，不直连 MySQL、Redis、TX-Node、SSH、Docker 或通用 Shell。

如果选择的旧镜像标签尚未包含内置 MCP Gateway，安装器会在正式启动前明确拒绝开启 MCP，避免产生“配置已开启但运行时不存在”的假成功状态。

已有部署可以运行：

```bash
sudo txboard config
```

然后选择 **MCP Gateway** 交互式开关。切换会重建 TXBoard 容器并等待 healthcheck；如果启动失败，部署工具会恢复原配置。

无人值守安装支持：

```bash
sudo env TXBOARD_ENABLE_MCP=true bash install.sh --yes ...
```

或显式参数：

```bash
bash install.sh --enable-mcp ...
bash install.sh --disable-mcp ...
```
