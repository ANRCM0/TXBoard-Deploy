#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
target="${1:?new fixture directory required}"
test ! -e "$target"
mkdir -m 700 -p "$target/single" "$target/multi"
export INSTALL_DIR="$target/single" APP_NAME=tx-node-fixture
source "$repo/node/deploy.sh"
public=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
pin=(--authorization-core-instance-id core-example-01 --authorization-key-id core-key-1 --authorization-key-epoch 1 --authorization-public-key "$public")
parse_install_args --mode node --provider txboard --panel-url https://core-a.example.test --node-id 7 --token synthetic-only "${pin[@]}"
write_config_files
INSTALL_DIR="$target/multi"
CONFIG_FILE="$INSTALL_DIR/config.yml"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
write_config_files
wrap_config_as_instances
parse_install_args --mode machine --provider txboard --panel-url https://core-b.example.test --machine-id 12 --token synthetic-only "${pin[@]}"
render_instance_block > "$target/new-instance.yml"
append_instance_block "$target/new-instance.yml"
echo 'single and multi-instance authorization fixtures rendered'
