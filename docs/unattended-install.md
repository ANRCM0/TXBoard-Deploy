# 无人值守安装与参数

以下参数来自当前部署 README 的自动化安装说明。仅在隔离环境充分测试后进行无人值守部署；已有业务数据时不得将新安装命令当作升级器。

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
