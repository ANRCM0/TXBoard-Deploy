# TXBoard Deploy 运维与升级

本页保留完整的运维菜单、更新流程、服务发现和数据安全说明。执行破坏性操作前先确认实际部署版本、容器身份和已验证的备份。

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

已有旧部署不需要重装，也不需要为了获取新管理命令而升级 TXBoard 镜像。可以只刷新管理脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main/update.sh | sudo bash -s -- --tools-only
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
13) Reset administrator password
14) Maintenance tools
15) Refresh manager scripts
16) Reset admin panel security path
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
sudo txboard admin-reset-password       # 交互式重置管理员密码（自动生成）
sudo txboard admin-reset-password admin@example.com
sudo txboard admin-reset-path              # 交互式重置管理面板安全路径
sudo txboard repair-command             # 修复 /usr/local/bin/txboard 命令
sudo txboard install-status             # 检查 Laravel 安装状态
sudo txboard clear-runtime-cache       # 仅清理配置/路由/视图缓存
sudo txboard restart-horizon           # 平滑重启 Horizon 队列
sudo txboard maintenance-menu
sudo txboard refresh-manager             # 仅刷新运维脚本，不更新镜像或数据库
sudo txboard help
```

### 管理员密码及管理面板安全路径恢复

如果忘记管理后台的安全路径，或需要轮换入口，可在具备服务器 Docker 权限的交互终端执行：

```bash
sudo txboard admin-reset-path
# 或：sudo txboard -> 16) 重置管理面板安全路径
# 也可在「9 配置管理」的第 6 项，或「14 运维工具」的第 6 项使用
```

工具会要求输入 `Y` 二次确认，并调用 TXBoard **镜像内**的 `php artisan txboard:admin-path-reset`。后端生成新的 128-bit 随机路径，写入数据库原生 `secure_path` 设置并使设置缓存失效，只在当前终端显示新入口；**旧管理入口立即失效**，应立即更新书签。不会重置管理员密码、订阅密钥、数据库或 Docker 数据卷。

**版本依赖**：先更新 TXBoard 镜像到包含 `txboard:admin-path-reset` 的版本，再使用此菜单。只执行 `refresh-manager` 仅更新菜单，不能给旧镜像增加 Artisan 命令；旧镜像下操作会安全失败，并提示升级。非交互环境与未确认操作均不会修改路径。不要在共享日志、屏幕录制或 CI 中传播新的管理入口。

忘记管理员密码时，执行 `sudo txboard admin-reset-password`，确认管理员邮箱并输入 `Y`。命令复用 TXBoard 已有的 `php artisan reset:password`，自动生成新密码并**只打印到当前终端**；旧密码立即失效，不会删除数据库、用户或 Docker 数据卷。请在安全的本地终端操作，避免录制会话输出。也可以传入当前管理员邮箱；安装时记录的邮箱可能已被修改。请勿通过命令行参数传递明文密码。注意：后端现有的重置命令按邮箱查找用户，请确保输入的是实际**管理员**邮箱，避免误修改普通用户。

如果管理命令丢失，但部署目录还在，可运行：

```bash
sudo bash /opt/txboard/txboard.sh repair-command
```

仅修复当前部署到 `/usr/local/bin/txboard` 的符号链接，不会覆盖已有普通文件或指向其他部署的链接。非默认路径使用 `sudo bash /实际目录/txboard.sh --dir /实际目录 repair-command`。旧版脚本尚无此子命令时，可通过前述 `update.sh --tools-only` 入口刷新，不要重新安装、升级镜像或重置数据库。

`refresh-manager` 将先下载最新安全更新器，再仅刷新运维脚本和模块，自动校验 Shell 语法；不触碰运行中的容器、业务数据库和镜像。下载或验证失败会保留旧脚本。`install-status` 检查 Laravel 初始化状态；`clear-runtime-cache` 只清理配置、路由及视图缓存，**不运行 `cache:clear` 或 `optimize:clear`**，避免意外清空与队列、会话共用的 Redis；`restart-horizon` 请求 Horizon 平滑退出，由 Supervisor 自动重启。上述 Artisan 操作需要 TXBoard 容器处于运行状态。

备份管理支持创建、查看、恢复、删除和修改保留数量。内置 MySQL 模式下，恢复前会自动创建一次不参与保留数量裁剪的安全备份，并保留当前访问 URL / Cookie 安全设置；宿主机 / 外部 MySQL 模式仍支持备份，但自动整库恢复会被禁用。完整卸载前也会先备份，并把部署目录额外打包到用户 HOME 目录。

配置菜单可以切换 Caddy 自动 HTTPS、外部 HTTPS 反向代理和 HTTP 模式，并同步修改 Docker 端口映射、`APP_URL` 与安全 Cookie 配置。也可以交互式启用/关闭主镜像内置的 MCP Gateway；配置应用失败时会恢复修改前的配置文件。

## 启动前服务发现（安装 / 更新 / 管理）

安装或镜像更新前，脚本首先枚举 **整个 Docker Engine** 的容器（包含停止和异常的实例），识别 Compose 的 `service=txboard`、`project`、`working_dir` 标签与镜像，核对当前安装目录和 `docker compose ps -a -q txboard` 是否实际指向**同一个**容器。容器名或镜像名不能单独证明拥有修改权限。

```bash
sudo txboard detect
sudo txboard status
```

`txboard detect` 显示容器名称、运行状态、健康状态、Compose 项目、安装目录、镜像与 ID。服务发现结果仅用于识别，不会修改容器或数据库。交互安装发现**当前目录内唯一健康实例**时，明确显示 **升级现有实例 / 不作修改退出** 菜单；不会直接调用安装目录里的旧更新脚本，而是下载并验证最新安全更新器后继续。`--yes` 始终拒绝覆盖现有服务。

| 发现情况 | 安装 / 更新处理 |
| --- | --- |
| 未发现 TXBoard、目标目录无部署配置 | 可按正常流程安装 |
| 目标目录已有唯一的 TXBoard 且健康 | 交互安装器提示改为更新现有实例（使用其当前镜像标签）；禁止重复安装或清理，更新仍经过完整数据库预检 |
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

## 原生数据库升级保护

升级安装入口首先检查当前运行中的 TXBoard、服务健康状况和数据库表结构。
只有完整原生 `tx_*` 数据库可以进行常规镜像更新。旧版 `v2_*` 或混合数据库
会在停止服务、拉取新镜像和执行迁移之前被拒绝；不再提供“保留旧表名升级”
或在线重命名切换。对 XBoard 数据迁入，请使用 [独立 SQL 备份导入流程](migration-from-xboard.md)。

常规更新仍会在写入前校验数据库、冻结 TXBoard 写入、创建校验完整的备份，
并在 Laravel 迁移后核对用户数、余额、佣金、订单及其金额。不允许 `--skip-backup`。
一旦 Migration 已尝试修改结构，失败会保持服务停止并要求人工从匹配备份恢复，
而不是用不兼容旧镜像继续启动。

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

本仓库的部署层可以公开分发，因为它主要描述“如何运行 TXBoard 镜像”。源码是否公开应以真实仓库可见性为准，不能将 Docker 镜像等同于源码保密措施。

它不包含：

- Laravel 应用源码
- React / Vue 源码
- TXBoard Dockerfile
- Composer / npm 构建过程
- 私有 Git 历史

但是需要区分两个概念：

> **源码仓库 Private，不代表 Public Docker image 内的文件不可提取。**

如果 `ghcr.io/anrcm0/txboard` 是 Public，那么能够拉取镜像的人仍可以查看镜像文件系统中实际包含的 PHP 文件。TXBoard Deploy 解决的是“源码仓库和部署分发解耦”，不是 Docker 镜像代码加密。
