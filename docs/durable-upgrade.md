# 持久升级编排：影子证据演练

`scripts/upgrade.py` 实现 `subscription-shadow/v1`、`plan-catalog-shadow/v1`、`commerce-shadow/v1` 与 `captured-money-shadow/v1` 的单机隔离副本演练：签名计划、只读预检、持久意图、受控迁移、分批回填、逐对象对账和崩溃恢复。它保留 `legacy` 权威，不切换生产 Writer，不启动新旧业务镜像，不删除旧表。完整 B2 的生产维护、共享集群租约、authority 切换和跨组件协议联调仍待实现和验收。

需要 Python 3.10+、OpenSSL、Linux、Docker Compose v2，以及包含 B1 影子命令的本地固定 digest Core 镜像。数据库必须是原生 `tx_*` 的隔离副本，`api.env` 同时包含 `APP_ENV=testing`（或 `local`）和 `CORE_SHADOW_ISOLATED_COPY=true`；所属 `txboard` 容器与滚动备份容器必须已停止。标记只是显式操作声明，不能自动证明连接的数据库与生产隔离，运维人员必须先核对复制目标与网络。未知数据库、`v2_*`、混合表、缺失 migration history、未知 migration/probe、生产/集群模式均拒绝。

从经过审查的本仓 checkout 执行。现有安装器和 `refresh-manager` 尚不分发 Python runner；只有包含 `scripts/upgrade.py` 的目录才能使用 `txboard upgrade`。工具不会自动安装发布信任公钥，也不会下载或运行 Manifest 指定的脚本。

```bash
python3 scripts/upgrade.py plan --dir /opt/txboard-copy \
  --manifest /srv/releases/shadow.json \
  --signature /srv/releases/shadow.signature.json \
  --trust-dir /etc/txboard/release-keys

# check/apply/recover 额外需要已验证备份与部署包；plan 不检查运行环境。
python3 scripts/upgrade.py check --dir /opt/txboard-copy \
  --manifest /srv/releases/shadow.json \
  --signature /srv/releases/shadow.signature.json \
  --trust-dir /etc/txboard/release-keys \
  --deploy-bundle /srv/releases/deploy.tar.gz \
  --backup /opt/txboard-copy/backups/20261012T120000Z \
  --backup-evidence /srv/rehearsals/backup-evidence.json
```

将 `check` 改为 `apply` 执行；中断后用 `recover`。`--max-batches` 默认 1000，达到预算会保留游标和未完成标记供下一次 `recover`。`status` 只读显示持久检查点，明确记录未探测当前 Docker/数据库，不根据容器健康猜测成功。所有命令的错误只输出有限 `error_code`，不会打印 SQL bindings、运行环境、业务行或 Core 原始错误。

## Manifest 与签名

Manifest 使用中央 [Upgrade Manifest v1](https://github.com/ANRCM0/TXBoard/blob/main/contracts/v2/upgrade-manifest/README.md) 的字段，并增加明确的 `profile` 和 `billing`。本次仅支持下列封闭 profile，中央虚构 v2 切换示例会被拒绝。字段、类型、协议主版本、ID/probe/recovery 组合、阶段顺序全部严格检查；未知字段不被忽略。

```json
{
  "manifest_version": "txboard.upgrade-manifest/v1",
  "profile": "subscription-shadow/v1",
  "release_id": "release-specific-id",
  "created_at": 1791770400,
  "components": {
    "core": {"version": "actual-core-version", "artifact": "ghcr.io/anrcm0/txboard@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "required": true},
    "deploy": {"version": "actual-deploy-version", "archive_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "required": true}
  },
  "compatibility": {
    "tested_tuple": {"core": "actual-core-version", "deploy": "actual-deploy-version"},
    "core_schema_read_epochs": [1], "core_schema_write_epochs": [1],
    "internal_api_major": 1, "secure_channel_major": 2, "node_protocol_majors": [1],
    "credential_provider_major": 1, "required_node_capabilities": []
  },
  "schema": {"family": "native_tx", "allowed_source_epochs": [1], "expanded_epoch": 1, "target_epoch": 1},
  "migrations": [
    {"id": "subscription-shadow-expand-v1", "phase": "expand", "from_epoch": 1, "to_epoch": 1, "checkpoint": "ddl-step", "probe": "subscription-shadow-shape-v1", "recovery": "probe_then_continue"},
    {"id": "subscription-shadow-backfill-v1", "phase": "backfill", "checkpoint": "legacy-user-id", "probe": "subscription-shadow-progress-v1", "recovery": "resume_cursor"},
    {"id": "subscription-shadow-verify-v1", "phase": "verify", "probe": "subscription-shadow-reconcile-v1", "recovery": "read_only_repeat"}
  ],
  "upgrade_policy": {"mode": "isolated_shadow", "order": ["expand", "backfill", "verify", "observe"], "old_image_allowed_after_migration": false, "contract_deferred": true},
  "backup_policy": {"required": ["mysql", "core-key-material", "plugin-private-data", "persistent-files", "deployment-config", "usage-receipts"], "checksum_required": true, "restore_rehearsal_required": true, "receipt_recovery_coverage_required": true},
  "billing": {"currency": "CNY", "billing_timezone": "Asia/Shanghai"}
}
```

上述 digest 仅为语法示例，必须替换为实际制品。currency/timezone 是经核对的副本设置，不是默认值。epoch 1 表示仍由 legacy 读写；影子扩展不声明 v2 authority。这里的协议值只用于限制演练 profile，不声称运行时已经实现 Internal API/SC/Provider v2。

发布方使用至少 2048-bit RSA 密钥， detached envelope 包含 `algorithm=rsa-pkcs1-sha256`、受信任 `key_id`、**原始 Manifest 字节** SHA-256、标准 Base64 `signature`。验证器使用 OpenSSL 的 SHA-256/RSA 验证，Manifest 改动或 envelope 中替换 digest 都无法沿用旧签名。公钥放在运维预配的 `--trust-dir/<key_id>.pem`，目录和公钥不得被 group/world 写入。仓库不包含正式发布密钥或可信发布声明。

```bash
# 仅发布身份在其受保护环境中签名；私钥不得交给部署服务器。
openssl dgst -sha256 -sign release-private.pem -out shadow.signature.bin shadow.json

# 制品打包必须包含当前执行器与探测模块；runner 校验两者与本地字节一致。
tar -czf deploy.tar.gz scripts/upgrade.py lib/detect.sh
sha256sum deploy.tar.gz
```

## 意图、探测与恢复

执行器使用与 `update.sh` 相同的安装目录 `.upgrade.lock` Linux flock。`.upgrade/state.sqlite3` 使用 SQLite `synchronous=FULL`、持久意图/结果和单调 executor generation；每次写 checkpoint 前检查 token。文件/目录权限是 0600/0700。副作用前落盘 intent；进程被 kill 后，缺失 result 表示结果未知，恢复先探测而非重放。检查点绑定安装身份、容器 ID、source/target image ID、OCI digest、部署配置摘要、Manifest 摘要和备份证据；变更数据库配置或制品不能沿用旧 run。

expand 只执行内置 `2026_10_12_000001_create_subscription_shadow_tables.php`。migration history 加十张表和关键唯一索引探测证明已应用；出现部分表但缺少 history 时进入 `recovery_required`，不会盲目重跑可能隐式提交的 DDL。这个 probe 不是全部列/FK 的形式化 schema 验证。当前 Deploy 切片仅自动恢复尚未开始的 DDL、已完整提交的 DDL 和已提交的回填批次；部分 DDL 必须调查，不能声明任意 DDL 中断都能自动继续。

backfill 仅调用 `core:subscriptions-backfill` 的限定参数和 `--isolated-copy`，读取 Core 持久游标；Core 将数据和游标同事务提交。`source_changed` 或未解决 exception 会阻断，即使批次已提交而执行器未收到结果。verify 从零逐页执行只读 `core:subscriptions-reconcile`，全部页 `passed=true` 且 `complete=true` 才通过；恢复会重新对账，不依赖上次内存中的成功页。

`.upgrade-in-progress` 标记在 mutation 前原子替换、文件和父目录 fsync。旧 `update`/`--tools-only`、管理 start/restart、配置重建、备份创建/恢复/删除、保留策略变更和卸载使用同一安装锁并拒绝绕过标记，以免滚动清理删掉本次恢复点；成功演练后也保留标记和停止状态，因为 `old_image_allowed_after_migration=false`，逐户影子对账不能证明旧 binary 兼容。紧急 `stop` 保留可用，不宣称所有管理命令都被锁住。`completed` 仅表示本 profile 演练完成。此标记与 local generation 不等于生产 Writer fence，更不等于集群租约。直接绕过管理命令运行 `docker` 不受本工具控制。

没有自动旧镜像恢复、`migrate:rollback`、切换 authority 或整库 restore 子命令。源码中的 injectable fixture backend 只供测试，生产 CLI 没有自定义 backend/command 入口。

## 备份与恢复边界

`check/apply/recover/restore-check` 验证既有备份集每个 `CHECKSUMS.sha256` 文件、gzip、APP_KEY 存在及完整数据集映射。文件名只允许备份目录内的简单名称，拒绝路径穿越和 symlink。需要 MySQL、Core key material、插件私有数据（无插件可空）、持久文件、部署配置、usage receipt 边界记录。

备份 evidence 使用 `txboard.backup-evidence/v1`，包含 `backup_id`、`manifest_sha256`、`datasets`（dataset → checksummed 文件名列表）、`rehearsal` 和 `recovery_coverage`。具体结构由 [测试夹具](../scripts/test-upgrade-orchestrator.py) 的 `BackupTests` 展示。`rehearsal` 包含 `passed=true`、校验列表内的 `report_file` 和数据库归档 `backup_checksum`；coverage 包含 `passed=true`、校验列表内的 `report_file`、decimal string `receipt_generation`/`revocation_version` 和 `post_backup_changes=none-isolated-copy`。

这些是**运维演练与覆盖报告的声明**，执行器不会凭 `passed=true` 自己生成 MySQL 恢复成功的证据。报告必须来自隔离 MySQL 导入、只读应用启动、ledger/epoch/归属和 receipt/revocation 检查；摘要校验不等于恢复演练。`restore-check` 只验证证据与边界，始终输出 `restore_executed=false`。存在备份后的付款、钱包、订单、ACK receipt 或凭据撤销增量时，这个隔离 profile 拒绝覆盖声明；生产恢复需要独立的外部支付对账、归档/Node 重放、receipt generation 更新、撤销版本不回退和新 lease 同步。

## 已执行验证与未验收项

```bash
python3 -B scripts/test-upgrade-orchestrator.py
bash scripts/test-upgrade-management.sh
```

Python 测试使用真实 SQLite 写入和真实子进程 kill：intent 后中断、DDL commit 后中断、回填数据/cursor commit 后中断、verify 成功后中断，恢复期间不会重复 DDL/用户记录；覆盖未知状态、manifest 改动、真实 RSA 签名篡改、并发锁、过期 token、逐户差异、缺少/篡改备份和恢复覆盖不足。Windows 与 Linux Python 下通过 33 项；Linux 下管理入口互锁、既有 native updater、管理员维护回归通过。CI 同时运行 Python 与管理互锁测试。

2026-10-12 在 WSL Alpine 的真实 Docker 28.3.3 / Compose 2.36.2 / MariaDB 11.4.12 上完成两次隔离副本演练：真实签名 `check/apply/recover` 成功；数据库归档导入独立恢复库后二次 dump 字节相等。测试 Core 镜像在仅 loopback 的临时 OCI registry 发布并实际拉取 digest `sha256:d2acbdf34908312c2d853accafc62166ec5e349cf02581fcd9d83daa848c100b`，使用虚构发布身份，没有正式发布授权。

[真实故障脚本](../scripts/test-upgrade-docker-recovery.py) 在新副本执行 Core 批次，commit 后、journal result 写入前对 executor 发 SIGKILL。检查点仍为 `backfilling`、result 为空，Core cursor 已为 `1`；恢复后逐户对账通过、重复 mapping 为 `0`、authority 为 `legacy`、容器保持停止、旧 binary guard 保留。故障脚本需要与 `apply` 相同的显式 `--dir/--manifest/--signature/--trust-dir/--backup/--backup-evidence/--deploy-bundle` 参数，只用于全新的隔离演练副本。它不提供 fixture 删除或生产 restore。

本地证据位于 `/opt/txboard-baseline/logs/upgrade-shadow-{check,apply,recover}.log` 与 `upgrade-shadow-docker-crash-recovery.log`；最后一次故障演练 Manifest SHA-256 为 `4bf03dc303cdfc5c89c40926a850d3bca880b29b5e225edc4dc88a6125c3c792`。备份、临时发布公钥和 checkpoint 位于 `/opt/txboard-baseline/upgrade-integration/`，不进入仓库。测试容器使用一个无套餐测试用户；这份证据不能代表真实匿名生产副本、所有业务例外或大规模回填验证。

## B2.2：商品目录演练 profile

`plan-catalog-shadow/v1` 使用相同签名、backup evidence、停止副本、互锁和持久 journal 门禁。它独立运行当前 Plan 目录捕获，不执行订阅 Terms 或财务权威切换。Manifest 的 billing context 仍必填；组件固定 digest，schema/read/write epoch 仍为 1。三个 migration 必须完整采用以下顺序，不能混用订阅 profile 的 ID：

| ID | phase | checkpoint | probe | recovery |
| --- | --- | --- | --- | --- |
| `plan-catalog-shadow-expand-v1` | expand | ddl-step | plan-catalog-shadow-shape-v1 | probe_then_continue |
| `plan-catalog-shadow-backfill-v1` | backfill | legacy-plan-id | plan-catalog-shadow-progress-v1 | resume_cursor |
| `plan-catalog-shadow-verify-v1` | verify | 无 | plan-catalog-shadow-reconcile-v1 | read_only_repeat |

expand 固定执行 `2026_10_12_000002_create_plan_catalog_shadow_tables.php`，检查 migration history、六张表和三个关键唯一索引；部分 DDL 仍进入 unknown，不能盲目重试。backfill 固定调用 `core:catalog-shadow --isolated-copy`，游标与证据由 Core 原子提交，未解决 exception 阻断。verify 固定调用同命令的 `--reconcile`：检查每页 read-only/current-pointer-and-offers 标记、上下文/源增长/漂移、整数游标、升序对象 ID、条数、所有对象无问题，直到 `has_more=false`。恢复每次从零对账，observe 只确认已完成核对，副本保持停止。

该 report 只验证当前 revision/offers，不验证 superseded history 或部署后的实时写入追平。完整规则见 [Core 商品影子契约](https://github.com/ANRCM0/TXBoard/blob/main/contracts/v2/plan-catalog-shadow-v1.md)。本 profile 不宣称完整 B1/B2 完成。

Windows/Linux 的升级测试均为 40 项通过。新增验证包括混合 profile 拒绝、部分 DDL、已提交异常、全部分页、无进展/伪清洁页拒绝，以及丢失结果后的恢复。真实 Docker/MariaDB 演练使用 committed Core `12e84357c5af2dcfba8f3f058f997aabd896d890` 的固定本地 OCI fixture；数据库 dump 在独立恢复库逐字一致。Core 批次提交后、journal result 前 SIGKILL，持久 cursor=2；恢复后重复映射为 0、全部当前商品对账通过、旧 binary guard 保留。最终严格分页 adapter 再用真实 Core 执行只读核对通过。

演练 Manifest SHA-256：`a790eaf762dfa6d962e066142276aee254b37e3b26c5e5e1b416807885a0b388`；fixture OCI digest：`sha256:52c534dd4f97ca16999f2aa47a6f99828241206d1c91f83b7f41c440618ed849`。本地证据保留于 `/opt/txboard-baseline/catalog-upgrade-integration/`。它是合成数据和本地镜像演练，未使用生产发布签名、真实站点副本或 Oracle MySQL 8。

## B2.3：期初余额与订单证据演练 profile

`commerce-shadow/v1` 捕获当前用户的 wallet/commission 期初平衡分录及当前订单证据，使用同一签名、备份、停止副本与持久 journal 门禁。它消费 [Core 财务影子契约](https://github.com/ANRCM0/TXBoard/blob/main/contracts/v2/commerce-shadow-v1.md)，不发行付款、退款或真实 ledger 操作。三个 migration 必须采用以下顺序：

| ID | phase | checkpoint | probe | recovery |
| --- | --- | --- | --- | --- |
| `commerce-shadow-expand-v1` | expand | ddl-step | commerce-shadow-shape-v1 | probe_then_continue |
| `commerce-shadow-backfill-v1` | backfill | legacy-user-order-id | commerce-shadow-progress-v1 | resume_cursor |
| `commerce-shadow-verify-v1` | verify | 无 | commerce-shadow-reconcile-v1 | read_only_repeat |

expand 固定执行 `2026_10_12_000004_create_commerce_shadow_tables.php`，探测 history、七张表与七个关键唯一索引；部分 DDL 仍要求调查。backfill 仅调用 `core:commerce-shadow --isolated-copy`，`run` 与 `snapshot` 固定为本次 release ID，currency 来自签名 Manifest。两个 Core 游标及证据原子提交；任何未解决 exception 阻断恢复，不自动重试或覆盖变动证据。

verify 先完整扫描 user，再从零扫描 order。每页检查只读范围、snapshot/currency、固定 context hash/checkpoint version、双 high-water、无源增长/全局异常、升序 ID、条数与整数游标，两个对象类型均结束才允许 observe。进程重启后重新执行全部只读页，成功演练也保留旧 binary guard。分批核对依赖 writer 已停止的隔离副本，不证明实时跨页快照一致性。

Windows/Linux 最终升级套件均为 48 项通过。真实 Docker/Core `7622cab092a43fd07f901f6d3665d743f2146743`/MariaDB 演练使用一名有钱包和佣金余额的合成用户及一笔订单，独立恢复库 dump 字节相等。Core user 批次提交后、journal result 前 SIGKILL；恢复继续订单游标并完成两个对象类型核对，checked count 为 2，重复 opening、重复 journal、不平衡 journal 均为 0，旧 binary guard 保留。

最终演练 Manifest SHA-256：`fd98d5b4efd09c62dd261d54040b8ba124b7653417094eb3d782d07cc045633c`；fixture OCI digest：`sha256:8f074bbaf7b2011a833b24ce2ff5fdae98b4971da2cb5a3aa3177990da43b310`。结果、签名、备份和 journal 保留在 `/opt/txboard-baseline/commerce-upgrade-rerun/`。首次演练恢复成功后，验证 SQL 使用 MariaDB 保留字导致结果脚本失败；修正别名后使用新的数据库/目录完整重跑，原证据保留于 `/opt/txboard-baseline/commerce-upgrade-integration/`。

## B2.4 单User捕获余额影子profile

`captured-money-shadow/v1` 接入主仓B1.19，仅处理签名计划指定的一位User。
计划必须额外包含封闭 `capture` 字段：`legacy_user_id`、`run_key`、`stream_id`、
`high_water`、`last_event_hash`。ID/上限是正十进制字符串，run_key使用原捕获上下文，
hash是该固定高水位的原事件摘要；billing也须与原捕获一致。其他profile拒绝capture字段。
来源stream ID/上限/尾hash/context hash每次检查，变化或不相符投影检查点拒绝，
不自行extend、重锚定或重写源。

固定迁移 `2026_10_13_000001_create_legacy_money_shadow_tables.php` 只扩展三表；
捕获表和原有完整migrations须事先存在。编排步骤限定为
`captured-money-shadow-expand/backfill/verify-v1`，对应shape/progress/reconcile probe，
backfill checkpoint为 `capture-sequence`。计划不能提供SQL、命令、文件路径或环境变量名。
Core容器临时使用内置money/capture开关及已签名run/currency/timezone，不修改api.env。

回填每次仅 `core:legacy-money-shadow --isolated-copy --user=<signed ID> --limit=100`。
Core事件/分录/余额端点/游标原子提交，丢失编排result后从SQL检查点恢复；已完成回填不重复。
verify从0扫描全部页，要求当前Core返回正确User/currency/high-water、闭合否认门禁、
read_only/page_ok、准确计数/分页和不变checkpoint hash。重启丢弃先前内存验收，
从0再读；最后observe保留legacy权威与旧binary保护标记。

Windows/Linux各58项编排测试和Linux管理互锁通过。固定Core `63f99cf` 的本地工程
演练镜像使用真实RepoDigest，205个合成捕获事件；首100条提交后强杀执行器，
恢复最终逐页核对205条，duplicate steps/unbalanced steps均0，停机标记保留。
源数据库dump→新测试库restore逐字节相同。真实Docker/MariaDB与日志/制品hash见
[验证记录](captured-money-upgrade-verification.json)。这不是官方生产镜像或生产发布签名验收；
它不开放全站writer fence、资金权威、集群租约或自动整库恢复。

MySQL 8.4 DDL/并发/恢复仍未验收，MariaDB 不替代该门禁。Redis drain、集群 fencing、生产 Writer switch、Gateway/Node 协议联调、Provider 备份/租约恢复、正式签名发行与真实生产数据副本仍缺证据；本次完成的是单机隔离影子编排切片，不能记为 B2 全阶段完成。

提交 `71cb340` 的远端58项编排回归和真实Gateway安装/失败镜像回退通过；
同一CI在host MySQL渲染时命中初始化临时socket服务的就绪竞争，整体失败。
安装器现在等待 `skip_networking=0` 的正式服务，CI通过TCP执行真实inventory查询；
原保护查询和遇到未知状态拒绝安装的行为保留。Linux启动/重启/超时拒绝、安装顺序、
服务发现及升级互锁回归通过，修正提交的远端结果另行记录。
