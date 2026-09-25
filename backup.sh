#!/usr/bin/env bash
# Back up and restore the core stack's settings in CONFIG_ROOT.
#
# Usage (on Linux, run with sudo: AdGuard Home and Tailscale store files as root):
#   sudo ./backup.sh                  make a backup (stops the stack briefly)
#   sudo ./backup.sh --no-stop        make a backup without stopping the containers
#   sudo ./backup.sh --list           list existing backups
#   sudo ./backup.sh --restore FILE   restore a backup (current config is kept aside)
#
# Settings in .env: CONFIG_ROOT, BACKUP_DIR (default ./backups), BACKUP_KEEP (default 7)
# .env itself is NOT in the backup: keep its secrets in your password manager.

set -euo pipefail

cd "$(dirname "$0")"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
fail() { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

[[ -f .env ]] || fail ".env not found. Run ./setup.sh first."
# shellcheck disable=SC1091
source .env

CONFIG_ROOT=${CONFIG_ROOT:-./config}
BACKUP_DIR=${BACKUP_DIR:-./backups}
BACKUP_KEEP=${BACKUP_KEEP:-7}

# Logs and query history that don't need restoring
EXCLUDES=(
  --exclude '*/logs'
  --exclude 'adguardhome/work/data/querylog.json*'
)

ARGS="$*"
MODE=backup
STOP=true
RESTORE_FILE=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-stop) STOP=false ;;
    --list)    MODE=list ;;
    --restore) MODE=restore; RESTORE_FILE=${2:-}; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

# Root-owned files (AdGuard Home, Tailscale state) can't be read otherwise
if [[ "$MODE" != list && "$(uname -s)" == Linux && $EUID -ne 0 ]]; then
  fail "Run with sudo: sudo ./backup.sh ${ARGS}"
fi

WAS_RUNNING=false
stop_stack() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found in PATH, so the stack can't be stopped. Continuing without."
    return 0
  fi
  if [[ -n "$(docker compose ps -q --status running 2>/dev/null)" ]]; then
    WAS_RUNNING=true
    info "Stopping the stack for a consistent backup"
    docker compose stop
  fi
}

start_stack() {
  if [[ "$WAS_RUNNING" == true ]]; then
    info "Starting the stack again"
    docker compose start
  fi
}

case "$MODE" in
  list)
    if ls "${BACKUP_DIR}"/config-*.tar.gz >/dev/null 2>&1; then
      ls -lh "${BACKUP_DIR}"/config-*.tar.gz
    else
      info "No backups in ${BACKUP_DIR}"
    fi
    ;;

  backup)
    [[ -d "$CONFIG_ROOT" ]] || fail "${CONFIG_ROOT} doesn't exist. Nothing to back up."
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    file="${BACKUP_DIR}/config-$(date +%Y-%m-%d_%H%M%S).tar.gz"

    [[ "$STOP" == true ]] && stop_stack
    # Start the stack again even if tar fails
    trap start_stack EXIT

    info "Writing ${file}"
    # Backups contain the Tailscale identity: readable by the owner only
    (umask 077 && tar czf "$file" "${EXCLUDES[@]}" \
      -C "$(dirname "$CONFIG_ROOT")" "$(basename "$CONFIG_ROOT")")
    info "Backup size: $(du -h "$file" | cut -f1)"

    # Keep only the newest BACKUP_KEEP backups
    old=$(ls -1t "${BACKUP_DIR}"/config-*.tar.gz | tail -n +$((BACKUP_KEEP + 1)))
    if [[ -n "$old" ]]; then
      info "Removing backups beyond the newest ${BACKUP_KEEP}"
      echo "$old" | while IFS= read -r f; do rm -f "$f"; echo "    removed $f"; done
    fi
    ;;

  restore)
    [[ -n "$RESTORE_FILE" ]] || fail "Usage: ./backup.sh --restore FILE (see ./backup.sh --list)"
    [[ -f "$RESTORE_FILE" ]] || fail "Backup not found: ${RESTORE_FILE}"

    warn "This replaces ${CONFIG_ROOT} with the contents of ${RESTORE_FILE}."
    read -r -p "    Continue? [y/N] " answer || answer=
    [[ "$answer" =~ ^[Yy] ]] || { info "Cancelled"; exit 0; }

    stop_stack
    trap start_stack EXIT

    if [[ -d "$CONFIG_ROOT" ]]; then
      aside="${CONFIG_ROOT}.before-restore-$(date +%Y-%m-%d_%H%M%S)"
      mv "$CONFIG_ROOT" "$aside"
      info "Current config moved to ${aside}"
    fi

    info "Restoring ${RESTORE_FILE}"
    tar xzpf "$RESTORE_FILE" -C "$(dirname "$CONFIG_ROOT")"
    info "Restore done. Delete ${aside:-the old config} once everything works."
    ;;
esac
