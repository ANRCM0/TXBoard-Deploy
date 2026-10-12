# 安装仓历史合并

2026-10-13，TXBoard-Deploy 在 `ac9b811afb540206080fe4b6ae08d9feb1423d85` 基础上，通过不 squash 的 Git subtree merge，将 TX-Node-Installer 的 `303fd425d9eb0853d4abe9b79b1c26c42c9ac241` 完整历史导入 `node/`。旧源仓没有删除或改写。

本仓成为 Core、Gateway、Node 的统一安装及主机生命周期入口；运行时代码与三组件镜像发布集中到 TXBoard 主仓（后续名 `tx-core`）。Core 新镜像名为 `ghcr.io/anrcm0/txboard-core`，旧 `txboard` 镜像继续作为兼容别名；Gateway 为 `txboard-gateway`，Node 新镜像为 `txboard-node`。

`txboard-node` 由主仓直接创建、发布新 OCI package，不把旧 `tx-node` package 转绑到主仓。Node 程序名 `tx-node`、CLI `txnode` 和数据目录保持原样；已有旧/自定义镜像配置不自动重写，新版官方渠道与远程更新拒绝对旧 package 自动切换。历史 package 和测试证据保留，当前安装边界见 [三组件安装](components.md)。

历史测试报告的仓库路径和提交保持原样。目录调整不会自行启用尚未通过生产迁移门禁的功能。
