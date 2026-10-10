#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/managed" "$temp/foreign"
export DETECT_TEST_DIR="$temp" DETECT_TEST_COMPOSE_ID=own DETECT_TEST_PROBE=pass
cat > "$temp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" ps -a --no-trunc --format "*)
    for f in "$DETECT_TEST_DIR"/fixture.*; do
      [[ -e "$f" ]] || continue
      basename "$f" | sed 's/^fixture\.//'
    done ;;
  *" inspect --type container --format "*)
    name="$(printf '%s\n' "$@" | tail -1)"
    cat "$DETECT_TEST_DIR/fixture.$name" ;;
  *" compose ps -a -q txboard "*) printf '%s\n' "$DETECT_TEST_COMPOSE_ID" ;;
  *" compose exec -T txboard php artisan txboard:install-status "*)
    [[ "$DETECT_TEST_PROBE" == pass ]] ;;
  *) printf 'unmocked docker invocation: %s\n' "$*" >&2; exit 7 ;;
esac
MOCK
chmod +x "$temp/bin/docker"
export PATH="$temp/bin:$PATH"
# shellcheck source=/dev/null
source "$repo/lib/detect.sh"

fixture() {
  local id="$1" dir="$2" state="$3" health="$4" project="${5:-txboard}" service="${6:-txboard}" image="${7:-ghcr.io/anrcm0/txboard:latest}"
  printf '%s|/%s|%s|%s|%s|%s|%s|%s/compose.yaml|%s|sha256:oldimage\n' \
    "$id" "$id" "$state" "$health" "$service" "$project" "$dir" "$dir" "$image" > "$temp/fixture.$id"
}
reset() {
  rm -f "$temp"/fixture.*
  rm -f "$temp/managed/compose.yaml" "$temp/managed/api.env" "$temp/managed/.env"
  export DETECT_TEST_COMPOSE_ID=own DETECT_TEST_PROBE=pass
}

reset
txboard_guard_install "$temp/managed" >/dev/null
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "accepted absent instance" >&2; exit 1; fi

reset
fixture own "$temp/managed" running healthy
txboard_guard_update "$temp/managed" >/dev/null
[[ "$TXBOARD_DETECT_TARGET_COUNT" == 1 && "$TXBOARD_DETECT_FOREIGN_COUNT" == 0 ]]
if txboard_guard_install "$temp/managed" >/dev/null 2>&1; then echo "installed over live deployment" >&2; exit 1; fi

reset
fixture own "$temp/managed" exited none
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "upgraded stopped instance" >&2; exit 1; fi
if txboard_guard_install "$temp/managed" >/dev/null 2>&1; then echo "installed over stopped instance" >&2; exit 1; fi

reset
fixture own "$temp/managed" running unhealthy
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "upgraded unhealthy instance" >&2; exit 1; fi

reset
fixture own "$temp/managed" running starting
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "upgraded starting instance" >&2; exit 1; fi

reset
fixture own "$temp/managed" running none
txboard_guard_update "$temp/managed" >/dev/null
export DETECT_TEST_PROBE=fail
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "trusted absent health without app proof" >&2; exit 1; fi

reset
fixture other "$temp/foreign" running healthy
if txboard_guard_install "$temp/managed" >/dev/null 2>&1; then echo "missed foreign running TXBoard" >&2; exit 1; fi
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "adopted foreign TXBoard" >&2; exit 1; fi

reset
fixture own "$temp/managed" running healthy
fixture other "$temp/foreign" running healthy
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "ignored second instance" >&2; exit 1; fi

reset
fixture own "$temp/managed" running healthy alternative-project
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "adopted mismatched Compose project" >&2; exit 1; fi

reset
fixture own "$temp/managed" running healthy txboard other-service ghcr.io/anrcm0/txboard:dev
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "trusted image without service label" >&2; exit 1; fi

reset
fixture own "$temp/managed" running healthy
export DETECT_TEST_COMPOSE_ID=different
if txboard_guard_update "$temp/managed" >/dev/null 2>&1; then echo "ignored Compose instance mismatch" >&2; exit 1; fi

reset
touch "$temp/managed/compose.yaml"
if txboard_guard_install "$temp/managed" >/dev/null 2>&1; then echo "deleted orphaned deployment configuration" >&2; exit 1; fi

echo "TXBoard service discovery safety tests passed"
