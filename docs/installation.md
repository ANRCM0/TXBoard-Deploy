# TXBoard Deploy 安装指南

本文件是部署脚本的安装与选型说明。全新安装前，请确认目标库为空、安装目录无已有部署，生产镜像使用已验收版本。

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

### 安装入口预检与旧目录保护

安装器在**询问 HTTP/HTTPS 模式、管理员邮箱和数据库设置之前**先枚举 Docker 上运行中及已停止的 TXBoard，并确认安装目录。当前目录有唯一健康实例时直接询问「**升级现有 TXBoard / 安全退出**」，无需填写新安装参数。其他目录实例、多个实例、健康异常或残缺的部署配置均拒绝新安装；不会为了重新安装而执行 `docker compose down`。

**真正的新安装**在最终部署摘要确认后才清理与 TXBoard 无关的目录残留；取消安装不会清空目录。对于 `--render-only`，只允许使用没有既有部署配置的路径；对 `--yes`，非空目录默认拒绝清理。仍有意清理纯文件残留时，需显式提供 `--clean-install-dir`；该选项不会绕过检测到的 TXBoard 服务与部署配置保护。

已有管理的 MySQL 数据卷同样不会在填写向导期间被删除。选择 `--reset-local-db` 或交互确认后只记录意图，**最终安装确认和服务重新核验之后**才会尝试删除旧卷；仍被容器使用的卷无法被强制移除。

对宿主机 MySQL，向导会在修改数据库用户/授权之前询问管理员确认，并检查目标数据库是否已有表；对外部/宿主机/内置 MySQL，启动 TXBoard 安装命令前会再次检查目标数据库**确实为空**。发现已有业务表或数据库状态未知时拒绝新安装，提示使用安全升级器。

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
