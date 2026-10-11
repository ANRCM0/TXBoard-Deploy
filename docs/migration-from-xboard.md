# 从 XBoard 安全迁入 TXBoard

**危险操作**：只允许使用旧生产库的备份，恢复到**独立空目标库**后校验；不得在原生产数据库上执行 TXBoard 数据转换。必须冻结业务写入并做真实恢复演练。以下内容保留安装器的详细导入约束。

## 从 XBoard 数据库迁入 TXBoard（独立数据库导入）

这不是镜像升级或原地数据库重命名。TXBoard 运行时只支持原生 tx_* 表。
新安装器的「从 XBoard SQL 备份迁入」模式仅修改独立、**空的目标数据库**，不会
连接或写入 XBoard 生产数据库。导入失败时旧系统不受影响，目标库应废弃后重新创建。

**准备：** 在旧 XBoard 上冻结写入后，使用拥有该库只读权限的 MySQL 账户生成一致备份，
保留原应用的 .env（必须包含 APP_KEY）。不要使用 mysqldump --databases 或 --all-databases；
备份必须为仅含单库表结构及数据、不含 CREATE DATABASE / USE 语句的 .sql.gz。
对于不停机的预演，可以先生成测试快照；正式切换需再次冻结支付回调、订单、队列、
节点流量写入方和计划任务并重新生成最终备份。

~~~bash
# 旧 XBoard 数据库的示例：按实际主机、库名与用户修改；交互输入密码
mysqldump --single-transaction --quick --set-gtid-purged=OFF \
  --default-character-set=utf8mb4 --no-tablespaces \
  -h 127.0.0.1 -u xboard_readonly -p xboard | gzip > /root/xboard.sql.gz
# 将原 XBoard Laravel .env 安全复制到新服务器 /root/xboard.env
chmod 600 /root/xboard.sql.gz /root/xboard.env
~~~

在全新服务器上使用安装器，选择 **2. 从 XBoard SQL 备份迁入**，指定源 SQL.gz、
原 XBoard .env、全新 TXBoard 数据库与原生镜像。也支持无人值守参数：

~~~bash
sudo bash install.sh --yes \
  --tag dev-sha-c8492dc2e120 \
  --email admin@example.com --mode http --public-host 127.0.0.1 \
  --install-type xboard-import \
  --xboard-dump /root/xboard.sql.gz \
  --xboard-env /root/xboard.env
~~~

说明：示例中的 dev-sha 是一次具体的原生代码构建，仅供预演。
正式上线须选用已验证发布版本。import 模式会保留旧管理员、密码哈希、用户 ID、
UUID、余额与订单；--email 不会创建新管理员。APP_KEY 从原环境复制到新 api.env，
以便历史加密数据保持可读取。源 .env 的旧数据库连接和 APP_URL 不会复制。

导入动作顺序：目标库空库检查 → SQL 备份离线安全检查 → 恢复到目标库
→ 从所选 TXBoard 镜像取得当前 migrations 名单 → 校验所有 v2_* 表映射和 Laravel
迁移历史 → 在目标库执行表名/迁移账本转换 → 新版 Laravel 剩余迁移
→ 逐用户关键字段、逐订单关键字段哈希核验 + 订单用户关联 + 管理员存在性检查
→ 才允许启动 TXBoard。导入报告位于 backups/xboard-import/，权限为私有。
不允许未知历史迁移、混合 tx_* 数据、插件自建未知表静默略过。

### 从上一次失败的安装继续（残留 Compose 配置）

如果上次导入失败后已生成 `/opt/txboard/.env`、`api.env` 或
`compose.yaml`，但没有任何属于 TXBoard 的 Docker 容器，安装器不会默认覆盖配置。
交互式重新运行时，会询问是否**归档**无主部署目录（默认 N）。
答应后仅记下归档意图；直到最终确认新安装且数据源备份成功，才将
`/opt/txboard` 整体安全移动至
`/opt/txboard.orphan-时间-随机值/deployment`。所有旧配置、私密环境文件、日志、
存储数据都完整保留（私有目录模式），不会删除 MySQL 容器、数据库或 Docker 数据卷。
如确认取消，原目录保持原样。已运行或已停止的 TXBoard 应用容器会始终阻止这种归档。

无人值守时需要明确指定 `--archive-orphan-dir`（或
`TXBOARD_ARCHIVE_ORPHAN_DIR=true`）。`--clean-install-dir` **不能**绕过对遗留
部署配置的保护。该方式不是升级现有 TXBoard，只适用于确定上一次全新安装中断，
需要保留原文件并重新执行安装的情况。

### 简洁安装进度与完整日志

交互安装默认显示真实的**阶段完成进度条**和当前任务的动态加载标识，
不再持续刷屏展示 Docker 镜像层、MySQL 或 Laravel 的原始输出。
完成的阶段才会推进进度；耗时不确定的镜像拉取、数据库导入等步骤
使用转动指示器，不猜测百分比。发生失败时展示最近的诊断输出，
并打印完整日志路径。

原始日志保存在 `/opt/txboard/backups/installer/install.log`（0600 权限），
可单独查看。添加 `--verbose`（或 `TXBOARD_INSTALL_VERBOSE=true`）
可继续看到实时完整输出，同时也保存日志。非交互/CI 环境保留
直接输出以便排障。**全新安装输出的一次性管理员密码不会被隐藏**，
需要保存；从 XBoard 导入时沿用原有账户，不会生成新密码。
手动执行 `docker compose logs` 仍会显示服务的原始运行日志，
不受安装器 UI 控制。

### 自动创建 XBoard SQL.gz 备份（推荐）

现在交互式选择 **安装类型 2 从 XBoard 迁入** 后，默认使用
**1 自动从本机 MySQL 导出 / 2 使用已有 SQL.gz**。脚本从原 XBoard
`.env` 自动读取 `DB_HOST` 和 `DB_DATABASE`，识别 1Panel / Docker MySQL
容器；匹配失败时可从检测到的容器列表中选择。

最终确认后，安装器会自动从源库生成只读 SQL 备份，保存到
`$HOME/txboard-xboard-import-backups/xboard-时间-随机后缀.sql.gz`。
每份备份包含独立 SHA256 清单，目录和文件权限仅授权当前系统用户。
导出错误或 gzip 校验失败会中止安装并清理不完整文件。
**XBoard 生产数据库始终不会被修改，目标库必须与源库不同。**

无人值守调用示例：

~~~bash
sudo bash install.sh --yes --xboard-auto-dump \
  --xboard-env /opt/xboard/.env \
  --xboard-source-container 1Panel-mysql-KIWu --xboard-source-db xboard \
  --db-mode host --db-container 1Panel-mysql-KIWu --db-name txboard \
  --email admin@example.com --mode http --public-host 127.0.0.1 \
  --discard-legacy-audit
~~~

若 `/opt/xboard/.env` 的 DB_HOST 和 DB_DATABASE 已经准确指向运行中的
Docker 容器及源数据库，上例的两项 `--xboard-source-*` 参数均可省略。
若无法从 MySQL 容器环境读取管理员密码，可设置
`TXBOARD_XBOARD_DB_ADMIN_PASSWORD`；交互安装则会提示输入。
目前自动导出仅支持本机 Docker / 1Panel MySQL；其他来源仍可提供 SQL.gz。

使用 `mysqldump --single-transaction --quick` 生成的是时间点快照。
**正式切换前仍应冻结 XBoard 业务写入、支付回调和队列，再生成最终备份**，
否则导出后发生的订单及余额变化不会自动迁入。
`--xboard-auto-dump` 与 `--xboard-dump` 不可同时使用；`--render-only` 不导出数据。

### 旧 XBoard Access Audit 插件：可选丢弃（仅隔离目标库）
旧审计插件表 `audit_access_logs`、`audit_ban_logs`、`audit_hourly_stats`、
`audit_node_status`、`audit_reports`、`audit_rules` 及对应 5 条
`2026_09_16_*` / `2026_09_17_*` 迁移记录，与 TXBoard 自带的原生审计结构不同。
**默认拒绝迁移**；如果已确认不需要保留旧插件数据，可在交互安装时明确同意，
或以 `--discard-legacy-audit`（环境变量 `TXBOARD_DISCARD_LEGACY_AUDIT=true`）开启。
仅恢复到**全新、独立且空的 TXBoard 目标数据库**后，才按精确白名单删除旧插件表及
历史迁移记录，随后由 TXBoard 原生迁移创建自己的审计表。原 XBoard 数据库、原始备份
以及核心用户/订单/余额等业务数据均不被删除。其他未知扩展表或迁移仍严格拒绝。
已执行但原生目录不再保留脚本的
`2026_03_28_050000_lowercase_existing_emails`、
`2025_11_29_000000_add_server_id_to_stat_user` 与
`2025_11_29_120000_update_stat_user_unique_constraint` 被识别为历史记录：
保留原结果和迁移记录，不重新执行；对旧 `server_id` 迁移附加结构校验。完整预演并核验应用层行为后才能正式切换。

**当前支持边界：** 主流程以标准 XBoard 历史结构为基线，非标准 fork、
自定义表/插件和不同版本可能被阻止。仅数据库迁入不等于完整业务迁移：
用户上传文件、主题与插件文件、外部支付回调域名、TX-Node 节点配置、
CDN/DNS/反代及密钥/接口仍需单独迁移或重新对接。导入前先在测试服务器演练，
恢复验证完成后再考虑正式业务切换。绝不在原生产 XBoard 数据库上运行导入器。

**旧版升级器：** update.sh 现在只接受完整原生 tx_* 表。原 v2_* 不能再使用
txboard update 或旧的 --cutover-plan 原地迁移；应使用上述新环境独立导入。
