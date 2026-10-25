# TXBoard Deploy

This repository is the operator toolkit for TXBoard Core and independent
TX-Node deployments. Core owns browser ingress; the standalone Gateway is
retired. Native installations use an immutable Core image, reviewed private
configuration and durable deployment intents.

## Before installing

Use a reviewed checkout or release of this toolkit. Prepare a separate private
configuration directory using the current Core preparation, module composition,
Provider and signing contracts. Keep it outside the installation directory.
Have Docker Engine, Docker Compose v2 and Python 3.10+ available. Review the
installer's options and capacity requirements before confirming changes:

```sh
bash install.sh --help
```

A typical native installation uses these existing installer options:

```sh
sudo bash install.sh --dir /opt/txboard \
  --native-config /root/txboard-private \
  --native-image ghcr.io/anrcm0/txboard-core@sha256:REVIEWED_DIGEST
```

Replace `REVIEWED_DIGEST` with the reviewed 64-character image digest. Do not use
that placeholder literally. The wizard validates private source structure and
host resources before provisioning, then prepares, probes and activates native
runtime. Existing databases, image updates and XBoard imports have separate
guarded flows; a failed installation is not permission to clear a database.

Fresh unattended installation requires both `--native-config` and
`--native-image`; `--yes` does not select a historical runtime implicitly.
`--legacy-compat` explicitly retains the historical installation flow for a
compatible old image. Its native browser administration APIs are unavailable.
XBoard imports retain their separate guarded flow. `--render-only` can preview
configuration without native inputs; it neither installs nor activates Core.

For a local HTTP deployment, use `--mode http --public-host 127.0.0.1
--http-port 8080`. The published address is then `127.0.0.1:8080`.
`--http-bind 127.0.0.1` (or `TXBOARD_HTTP_BIND`) selects an explicit listener
independently of the public hostname. IPv6 addresses are accepted and rendered
with Compose brackets. An explicit wildcard bind overrides loopback inference.
The existing external HTTPS mode keeps its loopback-only listener.

Native images use reviewed immutable references. For the explicit historical
tag-based flow, `latest` means a stable release tag, `dev` tracks main and
`preview` tracks prereleases. A failed pull reports the requested reference and
probes these three channels with bounded registry requests. Registry/network or
authentication failures leave availability unconfirmed. The installer never
switches channels or image repositories automatically; an available tag is not
evidence of freshness or release approval.

Management tools are downloaded and syntax-checked before image acquisition or
activation, so their recovery commands remain available after a later failure.
A download failure preserves installed tools and stops installation before
activation. An unrelated global `txboard` command is preserved; use the printed
absolute manager path if the global name belongs to another installation.
Relative invocations from a reviewed checkout keep that source location after
entering the deployment directory, so helper installation does not silently
fall back to downloading a different toolkit revision.

## Find the correct entry and inspect runtime

The installer prints the public site origin. It does not assume `/admin/` is
the administrator entry. On an image containing the Core diagnostic command:

```sh
sudo txboard core-diagnose
sudo txboard core-diagnose --show-admin-path
```

The first command returns a redacted `core-diagnostics/v1` JSON report. The
second explicitly reveals the private entry path; do not share its output.
Effective app/browser origins, authority state, worker epoch, Provider
registration metadata and module fingerprints are available without `tinker`,
direct SQL or source edits inside the container. Credentials, private key
contents and raw exception text are omitted by Core.

The helper is bounded by time and response size. An unhealthy running container
is still inspectable. With no running container it uses a temporary container
from the existing local Compose image, bypasses the application entrypoint,
uses private in-memory cache drivers, and does not pull/build an image, start
dependencies, publish ports or migrate a database. It never restarts the live
application automatically. Exit 1 preserves a valid degraded Core report.

If Core reports `CORE_DIAGNOSTICS_UNAVAILABLE`, check whether the image predates
`core:diagnose`; use a reviewed native image update to obtain the command.
`txboard refresh-manager` refreshes the helper but does not change that image.
`CORE_DIAGNOSTICS_TIMEOUT` means the bounded container command timed out.

The diagnostic helper inspects a reported container's Compose service and
working-directory labels before executing in it. Ambiguous or unrelated
containers are refused.

## Interrupted installation or update

Preserve the private inputs, install directory and original deployment intent:

```sh
sudo txboard native status
sudo txboard core-diagnose
sudo txboard native diagnose
sudo txboard native recover
```

Run recovery after addressing the reported prerequisite. Do not reinstall over
the original intent. The native offline diagnostic remains independent of
Docker and checks private configuration, recovery and backup material. The
combined `txboard diagnose` additionally includes service, resource and recent
log information; its full output is not a sanitized support bundle.

For a reviewed image update, use:

```sh
sudo txboard native update --image ghcr.io/anrcm0/txboard-core@sha256:REVIEWED_DIGEST
```

Retain APP_KEY, original PKI, immutable image references and verified backups.
Backup inspection is read-only: `sudo txboard native backup-check --archive TIMESTAMP`.

## Verification

Run application, container, database and workflow tests in GitHub Actions.
The CI workflow covers the diagnostic subprocess/ownership/privacy boundary,
toolkit staging failures, installer ordering, refresh behavior and native
deployment recovery. Local syntax and AST checks do not establish functional
acceptance. Core image installation and upgrade acceptance is maintained in
the Core repository and remains tied to its exact candidate image.
