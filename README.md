# TXBoard Deploy

> TXBoard 的公开部署层。  
> 本仓库只包含 Docker 部署脚本，不包含 TXBoard Laravel / React / Vue 应用源码。

TXBoard Deploy 的目标是让用户只接触**公开部署脚本 + TXBoard 容器镜像**：

```text
TXBoard source repository
        │
        │ build / CI
        ▼
ghcr.io/paimoncai/txboard
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
- Docker Engine
- Docker Compose v2
- 能访问 GHCR

运行：

```bash
curl -fsSL https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main/install.sh | sudo bash
```

即使脚本通过 pipe 执行，交互输入仍从 `/dev/tty` 读取。

如果安装在拉镜像、数据库检查或应用初始化阶段中断，安装器会留下 `.install-incomplete` 标记，并提前安装 `txboard` 管理命令。之后再次运行安装器会识别未完成状态，允许在**保留 Docker 命名卷/数据库数据**的前提下清理生成文件并重新安装。无人值守环境可显式使用：

```bash
sudo bash install.sh --yes --recover-incomplete ...
```

安装向导会询问：

- TXBoard 镜像标签，例如 `latest`
- 管理员邮箱
- 安装目录
- 公网访问模式
- 域名或 IP
- HTTP / HTTPS 端口
- 数据库模式（内置 MySQL / 外部 MySQL）
- 外部数据库的主机、端口、库名、用户名和密码
- 备份保留数量

## 数据库模式

安装时可以选择两种数据库模式：

### 1. 内置 MySQL

默认模式。部署脚本会启动 MySQL 8.4 容器、创建独立数据卷，并自动生成数据库密码与 root 密码。

为了避免“旧 MySQL 数据卷 + 新随机密码”导致 `SQLSTATE[HY000] [1045] Access denied`，新安装会检查固定的 `txboard_database-data` 卷：

- 未发现旧卷：正常生成新密码并初始化 MySQL。
- 交互安装发现旧卷：默认停止并保留数据；只有明确确认后才删除旧卷并执行全新安装。
- `--yes` 无人值守安装发现旧卷：直接失败，不会自动删除任何数据库数据。
- 确定旧卷可以丢弃时，可显式使用 `--reset-local-db`。该参数会永久删除旧 MySQL 数据卷。

例如完全重装测试环境：

```bash
curl -fsSL https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main/install.sh |
sudo bash -s -- --yes --reset-local-db \
  --email admin@example.com \
  --mode http \
  --public-host 127.0.0.1
```

> `--reset-local-db` 是破坏性操作，只用于确认不需要旧数据库内容的全新安装。生产环境出现残留卷时，应优先恢复原部署配置和数据库凭据，而不是删除卷。

### 2. 外部 MySQL

适用于已有 MySQL、云数据库或独立数据库服务器。安装器会：

- 不创建本地 `database` 服务和 `database-data` 卷
- 将外部数据库参数写入 TXBoard 运行配置
- 在正式安装前使用 MySQL 客户端执行 `SELECT 1` 验证数据库、账号和网络连通性
- 继续使用 backup 容器对外部数据库执行定时备份
- 为容器加入 `host.docker.internal -> host-gateway`，因此同机数据库可以使用 `host.docker.internal`

外部数据库需要提前创建目标数据库，并给 TXBoard 用户授予该数据库的建表、修改表、索引及数据读写权限。数据库地址必须能从 Docker 容器访问。

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
ghcr.io/paimoncai/txboard:latest
```

安装时可以输入其他 tag。

生成的 Compose **只有 image，没有 build**：

```yaml
txboard:
  image: ghcr.io/paimoncai/txboard:latest
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
curl -fsSL https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main/update.sh | sudo bash
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
sudo txboard recover             # 半安装状态下重新进入恢复流程
sudo txboard help
```

备份管理支持创建、查看、恢复、删除和修改保留数量。内置 MySQL 模式下，恢复前会自动创建一次不参与保留数量裁剪的安全备份，并保留当前访问 URL / Cookie 安全设置；外部 MySQL 模式仍支持备份，但自动整库恢复会被禁用。完整卸载前也会先备份，并把部署目录额外打包到用户 HOME 目录。

配置菜单可以切换 Caddy 自动 HTTPS、外部 HTTPS 反向代理和 HTTP 模式，并同步修改 Docker 端口映射、`APP_URL` 与安全 Cookie 配置。配置应用失败时会恢复修改前的配置文件。

## 更新

默认更新当前使用的 image tag：

```bash
curl -fsSL https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main/update.sh | sudo bash
```

切换到指定 tag：

```bash
curl -fsSL https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main/update.sh |
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

不希望更新前自动备份：

```bash
sudo bash update.sh --skip-backup
```

## 无人值守安装

CI 或自动化环境可以使用环境变量 + `--yes`：

```bash
curl -fsSL https://raw.githubusercontent.com/PaiMonCai/TXBoard-Deploy/main/install.sh |
sudo env \
  TXBOARD_MODE=auto-https \
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
TXBOARD_DB_MODE
TXBOARD_DB_HOST
TXBOARD_DB_PORT
TXBOARD_DB_DATABASE
TXBOARD_DB_USERNAME
TXBOARD_DB_PASSWORD
TXBOARD_DB_ROOT_PASSWORD
```

`TXBOARD_MODE`：

```text
auto-https
external-https
http
```

`TXBOARD_DB_MODE`：

```text
local
external
```

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

如果 `ghcr.io/paimoncai/txboard` 是 Public，那么能够拉取镜像的人仍可以查看镜像文件系统中实际包含的 PHP 文件。TXBoard Deploy 解决的是“源码仓库和部署分发解耦”，不是 Docker 镜像代码加密。

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
- 内置 / 外部数据库 Compose 渲染
- 残留内置 MySQL 数据卷的安全拒绝逻辑
- 完整 smoke install 后的管理命令与快捷子命令可用性
- 外部数据库探测和手动备份容器显式禁用 TTY，兼容 pipe / CI / 无交互输入
- 生成的 Compose 配置
- 生成的 Compose 不包含 `build:`
- 默认 TXBoard 公共镜像 manifest 可被匿名读取

