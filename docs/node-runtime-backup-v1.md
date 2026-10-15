# Node runtime backup v1 (Implementation slice)

This Installer-owned, same-deployment operation backs up `config.yml`, `docker-compose.yml` and the complete canonical persistent `data/` directory. It reuses Node's immutable pending/terminal traffic spools and signed authorization high-water files; it does not issue credentials, relabel traffic periods, change billing or activate isolated Usage v2.

## Quiescence and runtime identity

`txnode backup --full` checks Compose working-directory/service ownership and the exact container image ID. A running supported native Node is placed under restart policy `no` and receives the bounded runtime-checkpoint signal; no arbitrary command, URL or control-plane operation is introduced. Node closes its listeners/connections, samples its final counters and calls the existing durable terminal checkpoint without starting a new Core HTTP report. It joins previously admitted asynchronous reports; a blocked prior request fails at the bounded shutdown deadline and cannot obtain a success receipt. It exits only after all children join; a successful checkpoint returns process exit code zero and writes a private, fsynced checkpoint receipt. Timeout, SIGKILL, OOM or failed persistence cannot certify a graceful checkpoint. The Installer never force-kills a runtime to manufacture backup success.

The Linux capability is `node_runtime_checkpoint_v1`. The read-only `--backup-layout` probe loads and normalizes the selected configuration without opening listeners, contacting Core, loading cached user credentials or initializing authorization stores. Its fixed JSON contains target identities, public enrollment pins and persistent path roots, never bearer tokens or private keys. Layouts outside the canonical data mount, unsupported experimental usage modes and foreign containers are refused. Node's normal `--capabilities` remains read-only.

A snapshot of an already stopped process records that fact separately: it preserves existing durable files and makes no claim about volatile counters lost before the process stopped. A running capture requires a receipt belonging to its current container/process start. Configuration-only backups remain distinct and cannot restore an enrolled runtime.

## Private bundle

The format is `txnode.runtime-backup/v1`, an uncompressed private tar archive (`.tar`). The archive is private mode0600 and published atomically after fsync. Its manifest binds the canonical installation directory, component name, immutable image ID/repository digest, normalized layout, capture kind and a complete sorted inventory of relative paths, sizes, modes, ownership and SHA-256. `MANIFEST.json` plus regular files/directories under the two configuration filenames and `data/` are the only archive entries. The checksum detects corruption; it is not a release signature or encryption. No secrets or file contents appear in public result/error output.

Reject absolute/traversing paths, duplicate/unknown entries, symlinks, hardlinks, special files, truncated data, mismatched hashes and bounded size/count violations before changing a deployment. Do not extract an archive using unrestricted tar path handling. Do not follow symlinks in a source or restore target. Python3.10+ and Linux are required for the durable operation.

## Restore and crash recovery

`txnode restore --full <archive>` validates the complete bundle, exact deployment/layout and available immutable runtime image before publication. The target must be stopped. Existing configuration must match the saved configuration; changed credentials, pins or target scopes require a separately reviewed re-enrollment flow. A fresh/missing target can be reconstructed only at the archive's original installation path.

Keep each current, validated authorization high-water record when it is newer than the archive's record. Equal revisions with conflicting bytes/identity are refused; rollback of key epoch, revision, issuance or observed time is refused. This never treats an on-disk snapshot as permission to reopen: restored Node must obtain a fresh online signed snapshot before listening.

Current-only immutable traffic spool files are retained byte-for-byte. Equal-path/equal-body files are shared. Equal-path/different-body pending or terminal records are refused before mutation rather than deleting or merging different batch identities. The operator must first reconcile/drain such records; no new batch ID or period is assigned by the Installer. Old already-settled backup batches may replay only under Core's existing idempotent receipt rules.

Build a verified replacement in a private sibling directory, persist a restore intent and guard marker, then publish by same-filesystem renames. Preserve the prior directory/configuration as a safety copy. An interrupted publication remains stopped and guarded; `runtime-recover` probes the recorded old/new paths and completes the same intent. Unknown/corrupt evidence refuses automatic recovery. A partially published restore must block start, restart, update, reconfiguration and purge. Restore/recovery leave the service stopped; startup is a separate validated operation.

## Required evidence and bounds

Unit/fault tests cover a full private bundle, exact traffic bytes/IDs, latest high-water retention, conflicting spools, path/link/corruption refusals, unavailable image and each rename interruption. Actual Docker evidence must exercise the Installer with Node, trusted local Core TLS, real VLESS/VMess traffic, current-process checkpoint, backup/restore, offline restart refusal, fresh online recovery and original receipt replay. Preserve each failed snapshot/database before retrying.

This is not host/disk anti-rollback against a privileged attacker, production key provisioning, cross-Core migration, HA, an arbitrary-volume backup tool or proof that all protocols have been accepted. Core/Gateway data and databases retain their separate Installer lifecycle and release gates.

## Operational entry points

```bash
txnode backup --full /root/txnode-runtime.tar
txnode restore --full /root/txnode-runtime.tar
txnode runtime-recover
txnode start
```

Backup and restore are serialized with the same private sibling `.<install-name>.runtime-operation.lock` held by lifecycle commands. The guard is the stable sibling `.<install-name>.runtime-restore.guard`, outside the components being replaced. Its presence, including malformed evidence, blocks mutating handlers reached through either CLI or interactive menus. Recovery validates recorded placements and the pinned image and leaves the process stopped.

The exact image is probed offline using `--capabilities` and `--backup-layout`; no credentials or persistent state are mounted into the capability probe. The layout probe mounts only the configuration read-only. Current Compose ownership, command, image environment and all three expected mounts must agree. Additional services/mounts, environment overrides and noncanonical layouts are refused.

`runtime_manager.py` owns Docker operations and imports the independent archive engine `runtime_backup.py`. A piped or persisted `deploy.sh` fetches missing helpers only from its configured installer source and verifies their complete release-bound SHA-256 before execution. LF checkout rules keep those hashes stable. Helpers can also be copied from the same full source checkout for offline operation.

Restore writes canonical Compose JSON (valid Compose YAML), fixes `image` to the locally verified immutable ID and keeps `restart` at `"no"`. A bound `x-txnode-origin-image` / `x-txnode-origin-id` records an official stable/dev source only when present in the saved deployment. Existing lifecycle helpers read this form; a later explicit official channel update removes the pin hint after selecting its approved tag. The backup archive remains private and contains credentials; it is not encrypted.

Implementation and local regression/synthetic Docker results are recorded in `node-runtime-backup-verification.json`. Full P1 single-host acceptance still requires real Core/TLS/signed authorization, VMess and installation/update/failure rollback gates. Review branches do not publish the supporting Node image.

The legacy configuration-only restore accepts only its known configuration backup names. It validates the current and selected YAML conservatively and refuses authorization declarations or ambiguous YAML syntax; it cannot add/remove enrollment through a config-only archive. Full runtime bundles cannot be selected or renamed into that path.
