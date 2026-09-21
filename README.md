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

安装向导会询问：

- TXBoard 镜像标签，例如 `latest`
- 管理员邮箱
- 安装目录
- 公网访问模式
- 域名或 IP
- HTTP / HTTPS 端口
- 备份保留数量

数据库首版固定使用脚本托管的 MySQL 8.4，并自动生成随机数据库密码。

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
├── backups/
└── data/
    ├── plugins/
    └── storage/
```

其中：

- `.env`：Docker Stack 参数与数据库随机密钥
- `api.env`：TXBoard Laravel 持久化运行配置
- `compose.yaml`：由交互参数生成，只引用镜像，不包含 `build:`
- `txboard.sh`：统一管理入口，提供安装、更新、服务、日志、备份、配置、诊断与卸载
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

主菜单提供：

```text
1) Install TXBoard
2) Update TXBoard
3) Service management
4) View logs
5) Backup management
6) Configuration
7) Diagnostics
8) Uninstall TXBoard
0) Exit
```

也可以不用菜单，直接调用子命令：

```bash
sudo txboard status
sudo txboard update
sudo txboard backup
sudo txboard diagnose
```

备份管理支持创建、查看、恢复、删除和修改保留数量。恢复前会自动创建一次安全备份；完整卸载前也会先备份，并把部署目录额外打包到用户 HOME 目录。

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
xboard:install-status
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
```

`TXBOARD_MODE`：

```text
auto-https
external-https
http
```

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
docker compose run --rm -e BACKUP_INTERVAL=0 backup
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
- `php artisan xboard:install`
- `php artisan xboard:install-status`

部署逻辑不应该依赖 TXBoard 源码目录结构。

## CI

本仓库 CI 验证：

- Bash 语法（install / update / manager）
- 非交互 render-only 安装
- 完整 smoke install 后的管理命令可用性
- 生成的 Compose 配置
- 生成的 Compose 不包含 `build:`
- 默认 TXBoard 公共镜像 manifest 可被匿名读取

