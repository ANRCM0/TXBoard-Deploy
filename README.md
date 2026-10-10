# TXBoard Deploy

> TXBoard 的公开部署层。  
> 本仓库只包含 Docker 部署脚本，不包含 TXBoard Laravel / React / Vue 应用源码。

TXBoard Deploy 的目标是让用户只接触**公开部署脚本 + TXBoard 容器镜像**：

```text
TXBoard source repository
        │
        │ build / CI
        ▼
ghcr.io/anrcm0/txboard
        │
        │ docker pull
        ▼
TXBoard Deploy
        │
        ▼
user server
```

部署脚本不会 clone TXBoard，不会运行 Composer、npm，也不会从源码构建应用。

## 一键安装

服务器需要：

- Linux amd64 / arm64
- 能访问 GitHub / GHCR
- Docker Engine + Docker Compose v2；交互安装检测不到时可选择自动安装 Docker

运行：

```bash
curl -fsSL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/install.sh | sudo bash
```

即使脚本通过 pipe 执行，交互输入仍从 `/dev/tty` 读取。安装器检测到 `curl | bash` / stdin 执行时，会先从同一 `TXBOARD_DEPLOY_RAW_BASE` 将完整安装器物化到临时文件，再从文件执行；原始 pipe 仅被排空，不再与 Docker、MySQL、MCP 等子进程共享“脚本源码 stdin”。这避免网络慢速流下子进程意外截断尚未被 Bash 解析的后续安装步骤。

安装向导会询问：

- TXBoard 镜像标签，例如 `latest`
- 管理员邮箱
- 安装目录
- 如果目标安装目录已经存在旧文件或旧 TXBoard 部署，是否清理后继续
- 是否启用测试部署模式
- 是否启用内置 MCP Gateway（Hermes / OpenClaw 等 AI Agent）
- 公网访问模式
- 域名或 IP
- HTTP / HTTPS 端口
- 数据库模式（内置 MySQL / 宿主机 MySQL 自动接入 / 外部 MySQL）
- 宿主机模式自动检测系统 MySQL、1Panel / Docker MySQL / MariaDB
- 外部数据库的主机、端口、库名、用户名和密码
- 备份保留数量

### 旧安装目录残留

安装器会在数据库配置前立即检查目标安装路径。只要目标是已有文件，或目录非空，就视为可能存在旧项目或安装残留：

- 交互安装会展示最多 12 个顶层文件/目录，并询问是否清理；默认选择 **N**。
- 确认清理后，如果存在 `compose.yaml`，安装器会先执行 `docker compose down --remove-orphans`，但**不会带 `-v`**，因此不会在这一步删除 Docker volumes。
- 随后清空目标安装目录，再继续正常安装流程。
- 内置 MySQL 的 `txboard_database-data` 仍由独立的数据保护逻辑管理；即使清除了安装目录，检测到旧数据库卷时仍会再次询问是否删除。
- `--yes` 无人值守安装发现非空目录时仍会安全退出；只有显式传入 `--clean-install-dir` 或设置 `TXBOARD_CLEAN_INSTALL_DIR=true` 才允许清理。
- 为避免误操作，安装器拒绝自动清理 `/`、`/opt`、`/var`、`/home`、`/tmp` 等系统级目录，也拒绝清理符号链接形式的安装目录。

例如无人值守清理旧文件后重新渲染：

```bash
sudo env \
  TXBOARD_INSTALL_DIR=/opt/txboard \
  TXBOARD_ADMIN_EMAIL=admin@example.com \
  TXBOARD_MODE=http \
  TXBOARD_PUBLIC_HOST=127.0.0.1 \
  bash install.sh --yes --clean-install-dir --render-only
```

> `--clean-install-dir` 只授权清理安装目录，不等于授权删除数据库卷。若还需要删除旧 managed MySQL 数据，必须另外显式使用 `--reset-local-db`。

## 数据库模式

安装时可以选择三种数据库模式：

### 1. 内置 MySQL

默认模式。部署脚本会启动 MySQL 8.4 容器、创建独立数据卷，并自动生成数据库密码与 root 密码。

为了避免“旧 MySQL 数据卷 + 新随机密码”导致 `SQLSTATE[HY000] [1045] Access denied`，新安装会检查固定的 `txboard_database-data` 卷：

- 未发现旧卷：正常生成新密码并初始化 MySQL。
- 交互安装发现旧卷：默认停止并保留数据；只有明确确认后才删除旧卷并执行全新安装。
- `--yes` 无人值守安装发现旧卷：直接失败，不会自动删除任何数据库数据。
- 确定旧卷可以丢弃时，可显式使用 `--reset-local-db`。该参数会永久删除旧 MySQL 数据卷。

例如完全重装测试环境：

```bash
curl -fsSL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/install.sh |
sudo bash -s -- --yes --reset-local-db \
  --email admin@example.com \
  --mode http \
  --public-host 127.0.0.1
```

> `--reset-local-db` 是破坏性操作，只用于确认不需要旧数据库内容的全新安装。生产环境出现残留卷时，应优先恢复原部署配置和数据库凭据，而不是删除卷。

### 2. 宿主机 MySQL（自动）

适用于这台服务器上已经存在 MySQL / MariaDB，尤其是 1Panel、Docker 或系统服务安装的数据库。

安装器会同时检测本机运行中的 MySQL / MariaDB Docker 容器与系统本地数据库：

- 交互安装同时存在 Docker 数据库和系统/宝塔本地数据库时，会把两类实例放在同一个菜单中供用户选择，不再由 Docker 数据库优先抢占。
- 检测到多个 Docker 数据库容器时，会逐个列出容器名称与镜像。
- 系统数据库优先查找 PATH 中的 `mysql` / `mariadb`，并兼容宝塔常见的 `/www/server/mysql/bin/` 与常见 `/usr/local/mysql`、`/usr/local/mariadb` 安装路径。
- 自动创建或更新 TXBoard 数据库用户与数据库，并生成随机应用密码。
- Docker 数据库会自动接入专用 `txboard-db-link` 网络，TXBoard 与 backup 容器直接通过 Docker 私网访问，不需要开放 3306 到公网。
- 无人值守模式继续保持原有兼容行为；需要指定 Docker 数据库时可用 `TXBOARD_DB_CONTAINER` 或 `--db-container`。

选择系统 MySQL / MariaDB 后：

- 先尝试 MySQL/MariaDB 客户端自己的默认 socket。
- 默认 socket 不可用时，会继续检查客户端 `--print-defaults`、当前活跃的 MySQL/MariaDB Unix socket，以及 `/tmp/mysql.sock`、`/run/mysqld/mysqld.sock`、`/var/run/mysqld/mysqld.sock`、宝塔常见目录等候选路径，并通过实际 `SELECT 1` 验证后再使用。
- 非标准环境仍可用 `--db-socket /path/to/mysql.sock` 或 `TXBOARD_DB_SYSTEM_SOCKET` 显式指定；指定值必须是当前存在的 Unix socket。
- 通过选定 socket 管理数据库并创建 TXBoard 数据库与用户。
- 先从临时 Docker 容器验证 `host.docker.internal` 是否能直连。
- 如果系统 MySQL 只监听 `127.0.0.1`，不会直接把 3306 改成公网监听；安装器会自动启用 `db-proxy` sidecar。
- `db-proxy` 只监听 Docker bridge 的宿主机网关地址，并转发到宿主机 `127.0.0.1:MySQL端口`，解决 Docker 无法访问 loopback-only MySQL 的问题，同时避免把数据库端口暴露到公网。

宿主机模式仍会在 TXBoard 正式安装前，从应用实际使用的 Docker 网络执行一次 `SELECT 1` 验证。

### 3. 外部 MySQL

适用于云数据库、独立数据库服务器或由你自行管理网络与权限的 MySQL。安装器会：

- 不创建本地 `database` 服务和 `database-data` 卷
- 将外部数据库参数写入 TXBoard 运行配置
- 在正式安装前使用 MySQL 客户端执行 `SELECT 1` 验证数据库、账号和网络连通性
- 继续使用 backup 容器对外部数据库执行定时备份
- 为容器加入 `host.docker.internal -> host-gateway` 兼容映射
- 交互安装输入 `127.0.0.1` / `localhost` 时会建议切换到“宿主机 MySQL（自动）”模式；无人值守模式会直接拒绝这两个地址
- 数据库探测失败时会明确提示检查数据库地址、防火墙和 MySQL 用户 host 权限

外部数据库需要提前创建目标数据库，并给 TXBoard 用户授予该数据库的建表、修改表、索引及数据读写权限。数据库地址必须能从 Docker 容器访问。同机 MySQL 建议直接选择宿主机模式，让安装器处理 Docker 网络或 loopback-only 访问。

HTTP 模式下的 “Public host / IP” 会写入 `APP_URL`。标准部署模式不允许填写 `0.0.0.0` / `::`；如果只是临时测试，可以在安装向导中启用 **test deployment mode**，此时允许使用通配地址，Compose 端口仍正常监听 `0.0.0.0`。测试模式会持久化为 `TXBOARD_TEST_MODE=true`，并在部署摘要与 `txboard config-show` 中显示。

> 外部数据库可以正常创建 TXBoard 备份，但管理器暂不自动执行整库恢复。恢复外部数据库时应使用数据库提供商/管理员工具导入 `backups/<时间>/db.sql.gz`，避免部署脚本在权限和托管策略未知的数据库上执行破坏性重建。

## 访问模式

### 1. Caddy 自动 HTTPS

适合服务器直接对公网提供 80 / 443：

```text
Internet
   │
   ▼
TXBoard Caddy
   ├── :80
   └── :443
```

输入域名后，TXBoard 内置 Caddy 负责证书申请和续期。

### 2. 外部 HTTPS 反向代理

适合 1Panel、Nginx、Cloudflare Tunnel 等：

```text
Internet
   │ HTTPS
   ▼
External proxy
   │ HTTP
   ▼
127.0.0.1:8080
   │
   ▼
TXBoard
```

脚本默认只把 HTTP 端口绑定到 `127.0.0.1`，避免绕过外部代理直接访问应用。

### 3. HTTP

适合测试环境或已经处于可信内网的部署。

## 安装结果

默认目录：

```text
/opt/txboard/
├── .env
├── api.env
├── compose.yaml
├── backup.sh
├── txboard.sh
├── update.sh
├── lib/
│   ├── common.sh
│   ├── service.sh
│   ├── backup.sh
│   ├── config.sh
│   ├── diagnose.sh
│   └── uninstall.sh
├── backups/
└── data/
    ├── plugins/
    └── storage/
```

其中：

- `.env`：Docker Stack 参数与数据库随机密钥
- `api.env`：TXBoard Laravel 持久化运行配置
- `compose.yaml`：由交互参数生成，只引用镜像，不包含 `build:`
- `txboard.sh`：统一管理入口，只负责菜单与命令路由
- `lib/`：服务、备份恢复、配置、诊断和卸载等独立运维模块
- `update.sh`：独立镜像更新器，包含更新前备份与失败自动回滚
- `data/storage`：上传文件与 Laravel 持久化数据
- `data/plugins`：用户安装的 TXBoard 插件
- `backups`：数据库、APP_KEY 和上传文件备份

敏感配置文件默认以 `0600` 创建。

## 镜像模型

默认：

```text
ghcr.io/anrcm0/txboard:latest
```

TXBoard 的 GitHub Actions 已将镜像发布分成三个独立通道。**正式版不会再随每次 main 提交自动更新**：

| 发布通道 | 镜像标签 | 更新触发 |
| --- | --- | --- |
| 正式版 Stable | `latest`、`v1.2.3`（示例） | 推送 Git 标签 `v1.2.3` |
| 预览版 Preview | `preview`、`v1.2.3-rc.1`（示例） | 推送 `v1.2.3-rc.1` / `-beta.N` / `-preview.N` 标签 |
| 开发版 Dev | `dev`、`dev-sha-<commit>` | 每次推送 `main` |

首次安装时可选择 `latest`、`preview`、`dev` 或固定版本标签。正式服务器推荐使用通过测试的具体版本（例如 `v1.2.3`），预发布环境使用具体预览版本或 `preview`，开发测试使用 `dev`。固定版本避免浮动通道更新导致部署目标不明确。

已安装实例切换通道或锁定版本：

```bash
sudo txboard update dev
sudo txboard update preview
sudo txboard update v1.2.3
```

这三个示例分别使用对应通道/版本；必须在 GHCR 已成功发布相应镜像后执行。应用的 `latest` 只会在推送正式发布 Git 标签后更新；未发布过新正式版时，`latest` 仍可能是旧版。

生成的 Compose **只有 image，没有 build**：

```yaml
txboard:
  image: ghcr.io/anrcm0/txboard:latest
```

因此用户服务器不需要 TXBoard 源码。

## 管理菜单

安装完成后，默认会保存管理脚本到：

```text
/opt/txboard/txboard.sh
```

以 root 安装时还会创建：

```text
/usr/local/bin/txboard -> /opt/txboard/txboard.sh
```

之后直接运行：

```bash
sudo txboard
```

已有旧部署不需要重装。执行一次新版更新脚本即可在更新成功后自动安装/刷新管理命令：

```bash
curl -fsSL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/update.sh | sudo bash
```

直接运行 `sudo txboard` 会进入交互菜单。未发现部署时只显示安装入口；已安装时主菜单提供常用运维操作：

```text
 1) Status
 2) Update
 3) Start services
 4) Stop services
 5) Restart TXBoard
 6) View logs
 7) Backup now
 8) Backup management
 9) Configuration
10) Diagnostics
11) Resource usage
12) Uninstall
 0) Exit
```

也可以完全跳过菜单，直接调用快捷子命令：

```bash
sudo txboard status              # 状态
sudo txboard ps                  # status 的快捷别名
sudo txboard start
sudo txboard stop
sudo txboard restart
sudo txboard stats               # 容器资源占用
sudo txboard logs                # 所有服务日志
sudo txboard logs txboard        # TXBoard 日志
sudo txboard logs database       # 内置 MySQL 日志
sudo txboard logs backup         # 备份服务日志
sudo txboard update
sudo txboard update latest
sudo txboard backup              # 立即备份
sudo txboard backups             # 查看备份列表
sudo txboard restore
sudo txboard config              # 配置菜单
sudo txboard config-show         # 直接查看配置
sudo txboard diagnose
sudo txboard help
```

备份管理支持创建、查看、恢复、删除和修改保留数量。内置 MySQL 模式下，恢复前会自动创建一次不参与保留数量裁剪的安全备份，并保留当前访问 URL / Cookie 安全设置；宿主机 / 外部 MySQL 模式仍支持备份，但自动整库恢复会被禁用。完整卸载前也会先备份，并把部署目录额外打包到用户 HOME 目录。

配置菜单可以切换 Caddy 自动 HTTPS、外部 HTTPS 反向代理和 HTTP 模式，并同步修改 Docker 端口映射、`APP_URL` 与安全 Cookie 配置。也可以交互式启用/关闭主镜像内置的 MCP Gateway；配置应用失败时会恢复修改前的配置文件。

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

## 启动前服务发现（安装 / 更新 / 管理）

安装或镜像更新前，脚本首先枚举 **整个 Docker Engine** 的容器（包含停止和异常的实例），识别 Compose 的 `service=txboard`、`project`、`working_dir` 标签与镜像，核对当前安装目录和 `docker compose ps -a -q txboard` 是否实际指向**同一个**容器。容器名或镜像名不能单独证明拥有修改权限。

```bash
sudo txboard detect
sudo txboard status
```

`txboard detect` 显示容器名称、运行状态、健康状态、Compose 项目、安装目录、镜像与 ID。服务发现结果仅用于识别，不会修改容器或数据库。

| 发现情况 | 安装 / 更新处理 |
| --- | --- |
| 未发现 TXBoard、目标目录无部署配置 | 可按正常流程安装 |
| 目标目录已有唯一的 TXBoard 且健康 | 禁止重复安装；允许该实例更新，随后执行数据库预检 |
| 已停止、正在启动、重启中、健康异常 | 安装与更新都阻断，先 `txboard status` / `txboard diagnose` / `txboard start` |
| 来自其他目录/不同 Compose 项目、多个 TXBoard | 不自动猜测实例，不安装、不升级、不清理 |
| 无容器但已有 `compose.yaml` / `.env` / `api.env` | 视为残缺旧部署，阻止覆盖，需要先恢复或检查 |
| 旧镜像无 Docker healthcheck | 运行中时需通过 `txboard:install-status` 检查才允许升级 |

出于安全考虑，当前安装器的 Compose 项目名固定为 `txboard`；**不能直接用第二个安装目录覆盖或共用相同的项目名**。后续如支持真正多实例，需要额外隔离 Compose 名称、端口、卷、网络与数据库。服务发现不会尝试替用户执行数据库恢复或卸载。

升级在拉取镜像后、停掉业务写入之前还会重复检查容器 ID、归属和健康状态，以防预检与执行之间被别人替换。即便使用 `--clean-install-dir`，如果检测到现存服务也会拒绝清理；Compose 停止失败同样禁止删除目录。仅用于模板渲染的 `--render-only` 可离线执行，但不会清除现有部署配置。

## 更新

默认更新当前使用的 image tag：

```bash
curl -fsSL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/update.sh | sudo bash
```

切换到指定 tag：

```bash
curl -fsSL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/update.sh |
sudo bash -s -- --tag latest
```

更新脚本默认先执行一次备份，然后：

```text
docker pull target-image
        ↓
docker compose up -d --force-recreate --wait txboard
        ↓
txboard:install-status
        ↓
失败时自动恢复旧镜像并重新拉起 TXBoard
```

更新器会记录更新前正在运行容器的 image ID。即使使用的是会移动的 `latest` 标签，更新失败时也会尝试把旧 image ID 重新标记回原标签后启动，因此不是只做字符串级的 tag 回退。

数据库感知升级**不允许**跳过完整备份：`--skip-backup` 会被明确拒绝，避免在不可逆迁移之后无法恢复。

## 镜像更新时的数据库自动识别与交互式切换

`sudo txboard update latest` 在更新镜像之前**只读检测当前实际 MySQL 表名**，按结果选择安全流程。数据库检测针对已有安装执行，不是每次应用容器重启时执行 DDL。

| 检测结果 | 更新行为 |
| --- | --- |
| 完整 `tx_*`，`TX_NATIVE_TABLES=true` | 不再询问旧库转换，直接备份、执行当前镜像常规 Migration、校验并重启 |
| 完整 `v2_*`，`TX_NATIVE_TABLES=false` | 交互显示 `1` 保留 `v2_*` 升级（默认）、`2` 审批后全量切换 `tx_*`、`0` 退出 |
| 空库、混合/不完整表、配置和表名不一致 | 阻止自动升级，不做 DDL |

旧库交互菜单：

```text
1) Upgrade application; KEEP v2_* table names (recommended)
2) Upgrade and rename ALL tables to tx_* (approved plan + verified restore required)
0) Cancel
Choice [1]:
```

选择 **1**：常规 Migration，原表名保留；自动备份数据库、APP_KEY、上传、插件与主题，校验账务数据和服务健康。选择 **2**：首先升级完整旧库，再用**已独立审核**的计划检查所有现存表的 `v2_* → tx_*` 映射，完成备份、在隔离环境实际恢复验证、Laravel 维护模式和明确审批后，才执行一次原子重命名，再设置 `TX_NATIVE_TABLES=true`、核验表与财务汇总、启动新版容器。插件、原生查询、支付回调、流量结算与旧版本兼容必须在预发副本完成业务验收。

一个已审核计划的路径可以在交互菜单中输入，也可将其作为**宿主机绝对路径**传给脚本：

```bash
sudo bash /opt/txboard/update.sh --tag latest --cutover-plan /secure/reviewed-plan.json
```

计划必须符合 [TXBoard 数据库全命名切换规范](https://github.com/ANRCM0/TXBoard/blob/main/docs/operations/native-mysql-table-cutover.md) 的全部要求：`schemaVersion=1`、`kind=native-table-cutover-plan`、`executable=true`、`requiresManualApproval=false`、`blockers=[]`，并且完整涵盖迁移之后的全部现存旧表。**内置自动计划生成器只输出不可执行的审核草稿，绝不可为运行方便自行改写审批字段。**

**重要：目前 `TX_NATIVE_TABLES` 并不能自动修复第三方插件与全部硬编码 SQL。选择 2 不代表 TXBoard 已通过所有生产环境兼容性审查；尚未完成完整审核和真实恢复演练时请选 1。**

`--yes` 无人值守对旧库只执行选项 1，不允许默许重命名；新 `tx_*` 库则无需提示。对 `tx_*` 执行新 Migration 之后，也会再次严格检查不能意外产生 `v2_*` 表，出现混合状态则停止服务并报告备份路径。

升级期间会停止 TXBoard 同容器 Web/队列/WS 写入，保留校验过的非轮转备份、哈希、镜像回退 ID。只有在**尚未尝试修改数据库**的失败情形下，才自动恢复旧镜像；执行过迁移或重命名之后，失败时保持停机，绝不强制将旧镜像启动到新数据库上。外部支付回调、插件或独立写入程序仍需运维方提前停用，且数据库备份文件必须定期演练可恢复性。

对于使用早期版本安装器的旧用户，首次执行本地 `txboard update` 可能仍会运行过时更新脚本。建议先下载新版 `update.sh`、做 `bash -n` 验证并从宿主机调用一次；新管理器之后会在升级前主动获取当前安全更新器：

```bash
curl -fL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/update.sh -o /tmp/txboard-update.sh
bash -n /tmp/txboard-update.sh
sudo bash /tmp/txboard-update.sh --dir /opt/txboard --tag latest
```

开发版本使用 `--tag dev`；它必须已由 GitHub Actions 成功发布。不应直接把未经预发验证的 dev 镜像和全量重命名应用到生产数据库。

## 无人值守安装

CI 或自动化环境可以使用环境变量 + `--yes`：

```bash
curl -fsSL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/install.sh |
sudo env \
  TXBOARD_MODE=auto-https \
  TXBOARD_TEST_MODE=false \
  TXBOARD_DOMAIN=panel.example.com \
  TXBOARD_ADMIN_EMAIL=admin@example.com \
  TXBOARD_IMAGE_TAG=latest \
  TXBOARD_DB_MODE=external \
  TXBOARD_DB_HOST=mysql.example.com \
  TXBOARD_DB_DATABASE=txboard \
  TXBOARD_DB_USERNAME=txboard \
  TXBOARD_DB_PASSWORD='replace-me' \
  bash -s -- --yes
```

支持的变量：

```text
TXBOARD_IMAGE_REPO
TXBOARD_IMAGE_TAG
TXBOARD_INSTALL_DIR
TXBOARD_ADMIN_EMAIL
TXBOARD_MODE
TXBOARD_DOMAIN
TXBOARD_PUBLIC_HOST
TXBOARD_HTTP_PORT
TXBOARD_HTTPS_PORT
TXBOARD_BACKUP_RETENTION
TXBOARD_TEST_MODE
TXBOARD_AUTO_INSTALL_DOCKER
TXBOARD_ENABLE_MCP
TXBOARD_DB_MODE
TXBOARD_DB_HOST
TXBOARD_DB_PORT
TXBOARD_DB_DATABASE
TXBOARD_DB_USERNAME
TXBOARD_DB_PASSWORD
TXBOARD_DB_ROOT_PASSWORD
TXBOARD_DB_ADMIN_PASSWORD
TXBOARD_DB_SYSTEM_SOCKET
TXBOARD_DB_CONTAINER
TXBOARD_DB_LINK_NETWORK
TXBOARD_DB_PROXY_PORT
TXBOARD_CLEAN_INSTALL_DIR
```

`TXBOARD_MODE`：

```text
auto-https
external-https
http
```

测试部署可以设置 `TXBOARD_TEST_MODE=true` 或使用 `--test-mode`。例如允许 `0.0.0.0` 作为测试用 Public host：

```bash
curl -fsSL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/install.sh |
sudo env \
  TXBOARD_ADMIN_EMAIL=admin@example.com \
  TXBOARD_MODE=http \
  TXBOARD_PUBLIC_HOST=0.0.0.0 \
  TXBOARD_HTTP_PORT=8852 \
  bash -s -- --yes --test-mode
```

`TXBOARD_DB_MODE`：

```text
local
host
external
```

宿主机数据库无人值守安装时，如果机器上只有一个可管理的 MySQL / MariaDB 容器会自动选择；存在多个时应设置 `TXBOARD_DB_CONTAINER`。如果数据库管理员密码无法从容器环境或系统 socket 自动获得，可设置 `TXBOARD_DB_ADMIN_PASSWORD`。 系统数据库使用非标准 Unix socket 且无法自动识别时，可设置 `TXBOARD_DB_SYSTEM_SOCKET`。

外部数据库无人值守安装至少需要设置 `TXBOARD_DB_HOST`、`TXBOARD_DB_USERNAME` 和 `TXBOARD_DB_PASSWORD`；端口默认 `3306`，库名默认 `txboard`。

内置 MySQL 的无人值守安装如果检测到已有 `txboard_database-data`，会安全退出。只有明确确认旧数据可删除时才追加 `--reset-local-db`。

## 常用运维

```bash
cd /opt/txboard

docker compose ps
docker compose logs -f txboard
docker compose restart txboard
docker compose exec txboard sh
```

手动备份：

```bash
docker compose run -T --rm -e BACKUP_INTERVAL=0 backup
```

不要随意执行：

```bash
docker compose down -v
```

这会删除 MySQL 等命名卷。

## 安全边界

这个仓库可以保持 Public，因为它只描述“如何运行 TXBoard 镜像”。

它不包含：

- Laravel 应用源码
- React / Vue 源码
- TXBoard Dockerfile
- Composer / npm 构建过程
- 私有 Git 历史

但是需要区分两个概念：

> **源码仓库 Private，不代表 Public Docker image 内的文件不可提取。**

如果 `ghcr.io/anrcm0/txboard` 是 Public，那么能够拉取镜像的人仍可以查看镜像文件系统中实际包含的 PHP 文件。TXBoard Deploy 解决的是“源码仓库和部署分发解耦”，不是 Docker 镜像代码加密。

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

