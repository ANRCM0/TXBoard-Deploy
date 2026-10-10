#!/usr/bin/env bash
# Discover all TXBoard containers (including stopped ones) before installation
# and upgrade. Ownership is based on Compose service, project and workdir labels.
# No filesystem or Docker mutations occur while this module is sourced.

txboard_detect_reset() {
  TXBOARD_DETECT_TOTAL=0
  TXBOARD_DETECT_TARGET_COUNT=0
  TXBOARD_DETECT_FOREIGN_COUNT=0
  TXBOARD_DETECT_TARGET_ID=""
  TXBOARD_DETECT_TARGET_STATE=""
  TXBOARD_DETECT_TARGET_HEALTH=""
  TXBOARD_DETECT_TARGET_IMAGE=""
  TXBOARD_DETECT_REPORT=""
}

txboard_detect_absdir() {
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$1"
  else
    (cd -- "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
  fi
}

txboard_detect_scan() {
  local install_dir="$1" ids cid raw name state health svc project workdir files image image_id owned
  local expected_dir
  txboard_detect_reset
  expected_dir="$(txboard_detect_absdir "$install_dir")"
  ids="$(docker ps -a --no-trunc --format '{{.ID}}')" || {
    printf '[TXBoard Detect] ERROR: cannot list Docker containers; operation blocked\n' >&2
    return 1
  }
  [[ -n "$ids" ]] || return 0

  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    raw="$(docker inspect --type container --format '{{.Id}}|{{.Name}}|{{.State.Status}}|{{with index .State "Health"}}{{.Status}}{{else}}none{{end}}|{{with .Config.Labels}}{{index . "com.docker.compose.service"}}{{end}}|{{with .Config.Labels}}{{index . "com.docker.compose.project"}}{{end}}|{{with .Config.Labels}}{{index . "com.docker.compose.project.working_dir"}}{{end}}|{{with .Config.Labels}}{{index . "com.docker.compose.project.config_files"}}{{end}}|{{.Config.Image}}|{{.Image}}' "$cid")" || {
      printf '[TXBoard Detect] ERROR: failed to inspect container %s; operation blocked\n' "$cid" >&2
      return 1
    }
    IFS='|' read -r cid name state health svc project workdir files image image_id <<< "$raw"
    # Recognize Compose service labels; also notice legacy/orphan containers
    # using official TXBoard image. Neither image nor name authorizes ownership.
    case "${image,,}" in
      ghcr.io/*/txboard:*|ghcr.io/*/txboard@*) : ;;
      *) [[ "$svc" == txboard ]] || continue ;;
    esac

    owned=foreign
    if [[ "$svc" == txboard && -n "$workdir" && "$(txboard_detect_absdir "$workdir")" == "$expected_dir" && "$project" == txboard ]]; then
      owned=target
    fi
    name="${name#/}"
    TXBOARD_DETECT_TOTAL=$((TXBOARD_DETECT_TOTAL + 1))
    TXBOARD_DETECT_REPORT+="$name | state=$state | health=$health | project=${project:-unknown} | dir=${workdir:-unknown} | image=$image | id=${cid:0:12}"$'\n'
    if [[ "$owned" == target ]]; then
      TXBOARD_DETECT_TARGET_COUNT=$((TXBOARD_DETECT_TARGET_COUNT + 1))
      TXBOARD_DETECT_TARGET_ID="$cid"
      TXBOARD_DETECT_TARGET_STATE="$state"
      TXBOARD_DETECT_TARGET_HEALTH="$health"
      TXBOARD_DETECT_TARGET_IMAGE="$image_id"
    else
      TXBOARD_DETECT_FOREIGN_COUNT=$((TXBOARD_DETECT_FOREIGN_COUNT + 1))
    fi
  done <<< "$ids"
}

txboard_detect_print() {
  if (( TXBOARD_DETECT_TOTAL == 0 )); then
    printf '[TXBoard Detect] No TXBoard containers found on this Docker daemon.\n'
  else
    printf '[TXBoard Detect] Found %d TXBoard container(s):\n%s' "$TXBOARD_DETECT_TOTAL" "$TXBOARD_DETECT_REPORT"
  fi
}

txboard_guard_install() {
  local install_dir="$1"
  txboard_detect_scan "$install_dir" || return 1
  txboard_detect_print
  if (( TXBOARD_DETECT_TOTAL > 0 )); then
    printf '[TXBoard Detect] ERROR: existing running/stopped TXBoard found. Installation and cleanup blocked.\n' >&2
    printf '[TXBoard Detect] Use the existing TXBoard manager to update/start/diagnose instead.\n' >&2
    printf '[TXBoard Detect] Separate instances need isolated Compose project names (the installer currently uses txboard).\n' >&2
    return 1
  fi
  # An incomplete installation can have no container but preserve credentials.
  if [[ -f "$install_dir/compose.yaml" || -f "$install_dir/api.env" || -f "$install_dir/.env" ]]; then
    printf '[TXBoard Detect] ERROR: existing deployment config in %s without an owned container. Recover or inspect it first.\n' "$install_dir" >&2
    return 1
  fi
}

txboard_guard_update() {
  local install_dir="$1" cid
  txboard_detect_scan "$install_dir" || return 1
  txboard_detect_print
  if (( TXBOARD_DETECT_TARGET_COUNT != 1 || TXBOARD_DETECT_FOREIGN_COUNT != 0 )); then
    printf '[TXBoard Detect] ERROR: expected one uniquely owned TXBoard and no unrelated TXBoard instances.\n' >&2
    return 1
  fi
  if [[ "$TXBOARD_DETECT_TARGET_STATE" != running ]]; then
    printf '[TXBoard Detect] ERROR: target TXBoard state=%s; use txboard status/diagnose/start before upgrading.\n' "$TXBOARD_DETECT_TARGET_STATE" >&2
    return 1
  fi
  case "$TXBOARD_DETECT_TARGET_HEALTH" in
    healthy) ;;
    none)
      if ! (cd "$install_dir" && docker compose exec -T txboard php artisan txboard:install-status --no-interaction </dev/null); then
        printf '[TXBoard Detect] ERROR: no healthcheck and application install-state probe failed.\n' >&2
        return 1
      fi
      printf '[TXBoard Detect] WARNING: legacy container has no healthcheck; install-state probe passed.\n' >&2 ;;
    *)
      printf '[TXBoard Detect] ERROR: TXBoard health=%s; diagnose before upgrading.\n' "$TXBOARD_DETECT_TARGET_HEALTH" >&2
      return 1 ;;
  esac
  cid="$(cd "$install_dir" && docker compose ps -a -q txboard)" || return 1
  if [[ -z "$cid" || "${TXBOARD_DETECT_TARGET_ID:0:${#cid}}" != "$cid" ]]; then
    printf '[TXBoard Detect] ERROR: discovered TXBoard and current Compose service are different containers.\n' >&2
    return 1
  fi
}
