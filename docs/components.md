# Core、Gateway、Node 统一安装

本仓负责三种组件的安装与主机生命周期。应用构建和镜像发布由 TXBoard 主仓（后续 `tx-core` runtime 仓）负责，安装器只拉取预构建镜像。镜像尚未发布或目标平台不可用时安装失败，不在服务器上临时构建应用。

| 组件 | 镜像默认值 | 默认目录 | 持久管理入口 |
| --- | --- | --- | --- |
| Core | `ghcr.io/anrcm0/txboard-core:latest` | `/opt/txboard` | `txboard`、`txboard core` |
| Gateway | `ghcr.io/anrcm0/txboard-gateway:latest` | `/opt/txboard-gateway` | `bash /opt/txboard-gateway/gateway.sh` |
| Node | `ghcr.io/anrcm0/tx-node:latest` | `/etc/txnode` | `txnode` |

从已检查的 checkout 可使用 `bash txboard.sh gateway ...` 或 `bash txboard.sh node ...`。Core 安装/刷新后的 `txboard` 也支持这两个组件子命令；Gateway 独立安装不会覆盖现有 `txboard` 快捷命令。组件脚本缺失时，统一入口从 `TXBOARD_DEPLOY_RAW_BASE` 下载、检查 Bash 语法并使用实际临时文件执行，避免与管道源码共用 stdin。下载源仍是受信任安装脚本分发渠道，并非签名供应链证明。

## Core 兼容

`sudo bash install.sh` 和 `sudo bash install.sh --component core` 行为一致，保留原 Core 安装参数、Compose 项目、服务、数据路径和持久升级互锁。新安装默认 `txboard-core`。原 `TXBOARD_IMAGE=ghcr.io/anrcm0/txboard:...` 的配置不会被自动迁移：`update.sh` 继续使用保存的仓库；旧 `txboard` 由发布方保留兼容别名。实例检测同时识别两个镜像名，仍须验证 Compose 归属。生产建议固定已验收的 tag 或 digest。

## 独立 Gateway

需要 Linux、Docker Engine、Compose v2、`flock`，不安装宿主机 Node。下面安装会真实拉取镜像、启动容器并等待 Docker healthcheck：

```bash
sudo bash install.sh --component gateway \
  --upstream https://core.example.com \
  --origins https://site.example.com
```

`--upstream` 是无凭据、路径、query 的 Core origin；`--origins` 是逗号分隔的精确浏览器 origins，不接受通配符。默认 HTTPS upstream；受信任的私有 HTTP Core 必须显式传 `--allow-private-http`，例如 `--upstream http://core:80`。容器内 `127.0.0.1` 指向 Gateway 容器自身，不能用它访问宿主机 Core。当前安装器不支持 IPv6 origin/bind。

默认宿主机仅绑定 `127.0.0.1:8787`。另行配置已有 TLS 反向代理，仅转发 `/gateway/v1/*`，不要公开 `/metrics` 等运维路径。使用 Docker 内反代时须自行提供可达的受控地址/网络；本安装器不自动修改 Core Caddy。`--bind` 可指定 IPv4 地址，改变可达范围前由操作者确认网络隔离与 TLS。它不设置 TLS，也不证明 Core 可达。`/healthz` 只证明 Gateway 进程存活，不代表业务、Core 权限或依赖已验收。

安装目录须专用空目录。`.env`、`gateway.env`、Compose 和私有 `diagnostic.log` 为 `0600`，目录与脚本为 `0700`。可用 `--operator-env /secure/gateway.env` 传入现有 dotenv 配置，安装器只复制、不执行或打印。首批仅允许 metrics token、host/ingress/upstream allowlist、请求/响应限制、超时和公共缓存 TTL；dotenv 中的 `$`/引号按 Compose 的 env_file 规则处理，应使用单引号保护 literal secret。此文件不能启用 HPKE、Redis、Internal 服务身份、注册/mail workflow 或订单写入，也不能传 Node 运行参数。任何 HPKE 私钥不属于本安装器范围，不创建、复制、挂载或打印密钥文件。运行镜像仍必须有默认关闭的这些配置。

```bash
sudo bash /opt/txboard-gateway/gateway.sh status
sudo bash /opt/txboard-gateway/gateway.sh logs
sudo bash /opt/txboard-gateway/gateway.sh stop
sudo bash /opt/txboard-gateway/gateway.sh start
sudo bash /opt/txboard-gateway/gateway.sh restart
sudo bash /opt/txboard-gateway/gateway.sh upgrade --tag dev
sudo bash /opt/txboard-gateway/gateway.sh remove --yes
```

`remove` 只移除该 Compose 项目容器/网络，保留所有配置、日志和镜像。使用 `--dir` 定位自定义安装；第二个安装还须使用唯一 `--project` 和可用端口。所有管理操作核验项目 working_dir、service、installer label，拒绝同项目的外来容器；修改通过非阻塞 `flock` 序列化。

升级保留安装的镜像仓库；`--tag` 只更换 tag，digest 安装不能用它静默换镜像。pull 失败保留原容器；新镜像不健康时用原容器的不可变 image ID 重新创建。回滚后 `.env` 的运行 image 为该 ID，原仓库/tag 独立保留，下一次升级仍从该原仓库选择。回滚失败会停止 Gateway，保留 `.gateway-update`，禁止 start/remove；保留镜像可用后运行 `recover`。进程中断留下的完整记录也走这个路径；不完整/损坏的记录拒绝自动恢复并需人工检查。此本地记录不声称具有数据库迁移或分布式持久恢复能力。Gateway 没有安装数据库，因此回滚不涉及 Core 数据恢复。

`--render-only` 只生成并通过 Compose `config --quiet` 验证配置，不拉取镜像或启动服务。此模式依然要求 Docker/Compose，不能替代真实镜像启动验证。命令输出不显示 operator env；Docker/Compose 诊断只写私有日志。日志及应用 `logs` 输出仍应按私密运维数据处理。

## Node 和旧入口

```bash
sudo bash install.sh --component node --mode machine --provider txboard \
  --panel-url https://core.example.com --machine-id 1 --token '<machine-token>'
sudo txnode status
sudo txnode upgrade stable
sudo txnode channel dev
```

这里委托 [原 Node 安装器](../node/README.md)，保留 `/etc/txnode`、data/config mount、host networking、多面板/多实例、legacy 导入、stable/dev 及受限 host update bridge；不授予容器 Docker socket。直接执行 `node/deploy.sh` 的 provider 默认仍为 `xboard`，TXBoard 用户应明确传 `--provider txboard`。统一入口的 `--dir` 须紧接组件参数，用于传递 Node 的 `INSTALL_DIR`；其他 Node 参数原样保留。

Node 自更新默认地址改为 `TXBoard-Deploy/main/node/deploy.sh`，持久化脚本与 `txnode` 快捷命令保持有效。显式 `SCRIPT_RAW_URL` 或旧 `TXNODE_INSTALLER_REPO` 覆盖继续兼容。已安装的旧脚本不会被远程改变；旧仓入口必须继续保留可用内容或发布兼容 bootstrap，操作者再执行一次受信任新脚本/刷新快捷命令后才获得新 URL。这次合并不删除、重写旧仓历史，也不承诺 GitHub 会自动为 raw URL 重定向。

## 验证范围

CI 保留 Core 既有门禁和 Node Installer 五套 shell 回归，新增三角色参数 literal 透传、本地/下载 materialization，以及 Gateway 合成 Docker 的安装/健康/升级/pull 失败/失败回滚/回滚再失败/恢复/锁/归属/私密配置回归。这些合成测试不执行 TX-Node binary，不证明 Node admission、HA、生产加密协议或真实官方镜像已发布。实际 Docker fixture 验证另行报告，不能以 mock 通过代替线上业务验收。
