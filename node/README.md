# TX-Node Installer

Public distribution entrypoint for TX-Node deployments.

This repository intentionally contains only deployment/bootstrap material. The TX-Node application source is maintained separately, while production hosts pull the public runtime image from GHCR.

## Install

Interactive install:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ANRCM0/TX-Node-Installer/main/deploy.sh)
```

Non-interactive machine install (used by TXBoard):

```bash
curl -fsSL 'https://raw.githubusercontent.com/ANRCM0/TX-Node-Installer/main/deploy.sh' \
  | sudo bash -s -- install --mode machine --provider txboard \
      --panel-url 'https://panel.example.com' \
      --machine-id 12 \
      --token 'MACHINE_TOKEN'
```

Optional non-interactive flags include `--provider xboard|txboard`, `--channel stable|dev` (default `stable`), `--kernel singbox|xray`, `--log-level`,
`--audit true|false`, and `--report-all true|false`. The non-interactive
defaults are `xboard` protocol, `singbox`, `info`, audit disabled, and `report_all=false`.

After installation, use:

```bash
txnode
```


## TXBoard remote runtime update

Docker deployments installed by the current Installer can expose the bounded **Machine Runtime Update v1** bridge used by TXBoard.

The bridge keeps deployment authority on the host:

```text
TXBoard
  -> typed Machine update request (latest only)
  -> TX-Node
  -> /run/txnode-update request file
  -> host systemd.path/service
  -> this Installer's existing upgrade runtime
```

The TX-Node container does **not** receive the Docker socket and TXBoard does not receive SSH or shell access. The bridge accepts only the fixed `latest` target for the official `ghcr.io/anrcm0/tx-node:latest` deployment.

Manual upgrades remain supported:

```bash
txnode upgrade
```

Both manual and remote upgrades use the same Installer-owned upgrade implementation. The remote path keeps the previous image until the new runtime passes stability/health checks and attempts an automatic rollback when verification fails.

Older installs remain compatible; if the bridge is unavailable, TXBoard should show remote update as unsupported and the operator can continue using `txnode upgrade`.

The runtime image defaults to:

```text
ghcr.io/anrcm0/tx-node:latest
```


## 镜像渠道（Stable / Dev）

本安装器只允许使用官方镜像：

- **稳定版**：`ghcr.io/anrcm0/tx-node:latest`，默认安装和生产升级渠道。
- **开发版**：`ghcr.io/anrcm0/tx-node:dev`，仅用于测试联调。
- 使用 `--channel stable|dev` 安装。例如 `txnode install --mode machine --provider txboard --channel dev ...`。
- 查看当前部署渠道：`txnode channel`；切换到开发版：`txnode channel dev`；切回稳定版：`txnode channel stable`。
- `txnode upgrade` 升级当前渠道；`txnode upgrade dev` 与 `txnode channel dev` 等效。命令会拉取镜像、重建容器并验证健康，失败时尝试恢复旧 Compose 文件和旧镜像。
- TXBoard 的远程 Runtime Update 只接受 `latest` 或 `dev` 目标；桥接不接受用户输入的任意镜像仓库、Tag 或脚本命令。旧版仅声明 `latest` 的桥接不支持远程切换开发版，须先升级 Installer。
- 在同一个共享容器内的多个 Panel 实例必须使用同一镜像渠道。安装命令请求的渠道与已运行容器不一致时会拒绝，避免静默安装成错误版本。需不同渠道请使用隔离部署。
- 更改 TXBoard 后台的 Machine 镜像渠道只是保存**预期安装渠道**、生成相应安装命令；不会自动影响已运行容器。应单独执行 Runtime 更新操作并确认结果。
- `dev` 标签只有在 TX-Node main 提交的镜像 CI 成功后才更新；部署开发版前确认对应镜像已发布。不会自动升级节点。

### Durable runtime data (S8)

New generated Compose layouts mount `$INSTALL_DIR/data` on `/etc/txnode` **before** overlaying the read-only `config.yml`. TX-Node defaults `kernel.config_dir` to that directory (or a per-instance/per-node child), so pending traffic batches, certificates and kernel state now survive Docker container recreation. Keep this directory on reliable persistent storage, writable by the runtime, and include it in backups.

**Existing deployments:** older Compose files that mount only `config.yml` and the update bridge do *not* become durable simply by upgrading this Installer. Before replacing an old container, stop it and migrate the data under its `/etc/txnode` (including hidden `.txnode-traffic-*.pending.json` files) to the new host `$INSTALL_DIR/data`, then add the directory mount ahead of the config-file mount. Check ownership and restore the previous Compose/container if health checks fail. Never overlay the old writable container layer with an empty host directory before preserving any pending traffic. Validate `txnode doctor` and reconcile pending batches against TXBoard's traffic ledger before considering the migration complete.

### Container config path

The canonical host and container config path is now:

```text
host:      /etc/txnode/config.yml
container: /etc/txnode/config.yml
```

New Compose files also pass `-c /etc/txnode/config.yml` explicitly. This keeps
the Installer compatible with older TX-Node images whose Docker default command
still referenced the historical path.

Already-generated Compose files that mount the host config into
`/etc/xboard-node/config.yml` remain upgradeable during the compatibility
window: current TX-Node images retain a bounded fallback only when the canonical
container config is absent, and the Installer's remote-update repair recognizes
both mount targets. New deployments do not generate the legacy container target.


## Multi-panel hosts

If the server already has a Docker TX-Node deployment, running the installer again no longer overwrites the existing configuration by default.

Interactive mode offers:

- **Add panel / instance** — recommended. The current single-panel config is preserved and converted to `instances:` when necessary, then the new Node or Machine target is appended.
- **Create isolated TX-Node** — creates `tx-node-2`, `/etc/txnode-2`, `/usr/local/bin/txnode-2`, then `tx-node-3`, and so on. Each isolated profile gets its own health port.
- **Overwrite current deployment** — explicit destructive reconfiguration for cases where replacement is actually intended.

The TXBoard non-interactive command is additive as well. If `install --mode machine|node ...` is run on a host that already has TX-Node, the supplied Panel + Machine/Node target is appended as a new instance. An identical target is treated as an idempotent no-op.

After installation, the same flows are available through:

```bash
txnode panel-add
txnode isolated-add
```

Before adding an instance, the installer backs up the existing config. It validates the restarted container, checks the configured health endpoint and obvious bind conflicts, and restores the previous config if the new instance cannot start cleanly.

## Architecture

```text
TX-Node source repository
        |
        | GitHub Actions / image publishing
        v
ghcr.io/anrcm0/tx-node (public)
        ^
        | docker pull / upgrade
        |
TX-Node-Installer (public deploy.sh)
        ^
        | curl
        |
      server
```

The installer repository must not contain TX-Node application source, private credentials, tokens, or production configuration.


## Legacy systemd installer

The public deployment path is the Docker-based `deploy.sh` above. The historical `install.sh` / direct binary-release path is frozen and is no longer a feature-development target.

Existing legacy installations can be imported into the canonical Docker deployment:

```bash
txnode migrate
```

After migration and verification, the Installer also owns cleanup of the old host runtime:

```bash
txnode legacy-cleanup
txnode legacy-cleanup --purge
```

The default cleanup removes the historical `xboard-node.service`, `xboard-node` binary and `xbctl` command while preserving `/etc/xboard-node` as a rollback/audit source. `--purge` removes that preserved legacy directory as well. Neither form deletes the canonical `/etc/txnode` deployment.

This keeps migration/cleanup authority in the Installer instead of requiring future TX-Node releases to keep shipping the old `xbctl` host-management runtime.

## License

The deployment script follows the TX-Node project's MPL-2.0 licensing.
