#!/usr/bin/env bash
# Standalone role dispatcher. No Core modules, Docker calls or secret output.
set -Eeuo pipefail

component_error() { printf '[TXBoard Components] ERROR: %s\n' "$*" >&2; exit 1; }
component_fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 60 "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$2" "$1"
  else
    component_error 'curl or wget is required'
  fi
}

component_main() {
  local role="${1:-}" command="${2:-help}" explicit_dir="${TXBOARD_COMPONENT_DIR:-}"
  [[ $# -ge 2 ]] || component_error 'usage: components.sh gateway|node command [options]'
  shift 2
  case "$role" in gateway|node) ;; *) component_error 'component must be core, gateway or node' ;; esac
  if [[ "$role" == node && "${1:-}" == --dir ]]; then
    [[ $# -ge 2 && -n "$2" ]] || component_error 'missing Node install directory'
    explicit_dir="$2"; shift 2
  fi
  local root target tmp='' result=0
  root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  target="$root/$role/deploy.sh"
  # An installed toolkit may only have lib/components.sh. A persisted Node
  # copy owns the existing CLI/bridge and is preferred over another download.
  if [[ "$command" != install && ! -f "$target" && "$role" == node && -f "${explicit_dir:-/etc/txnode}/deploy.sh" ]]; then
    target="${explicit_dir:-/etc/txnode}/deploy.sh"
  elif [[ "$command" != install && ! -f "$target" && "$role" == gateway && -f "${explicit_dir:-/opt/txboard-gateway}/gateway.sh" ]]; then
    target="${explicit_dir:-/opt/txboard-gateway}/gateway.sh"
  fi
  if [[ ! -f "$target" ]]; then
    tmp="$(mktemp /tmp/txboard-component.XXXXXXXX.sh)"
    if ! component_fetch "${TXBOARD_DEPLOY_RAW_BASE:-https://raw.githubusercontent.com/ANRCM0/TXBoard-Deploy/main}/$role/deploy.sh" "$tmp" || ! bash -n "$tmp"; then
      rm -f -- "$tmp"
      component_error 'cannot materialize validated component installer'
    fi
    chmod 700 "$tmp"
    target="$tmp"
  fi
  if [[ "$role" == node ]]; then
    if [[ -n "$explicit_dir" ]]; then
      INSTALL_DIR="$explicit_dir" bash "$target" "$command" "$@" || result=$?
    else
      bash "$target" "$command" "$@" || result=$?
    fi
  else
    local -a args=("$command")
    [[ -z "$explicit_dir" ]] || args+=(--dir "$explicit_dir")
    bash "$target" "${args[@]}" "$@" || result=$?
  fi
  [[ -z "$tmp" ]] || rm -f -- "$tmp"
  return "$result"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then component_main "$@"; fi
