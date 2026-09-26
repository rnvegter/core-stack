#!/usr/bin/env bash
# Back up and restore the core stack's settings, locally and optionally
# offsite to a Hetzner Storage Box (encrypted with restic).
#
# Usage (on Linux, run with sudo: AdGuard Home, NPM and Tailscale store files as root):
#   sudo ./backup.sh                          make a backup (stops the stack briefly);
#                                             also uploads offsite if OFFSITE_ENABLED=true
#   sudo ./backup.sh --no-stop                same, without stopping the containers
#   sudo ./backup.sh --local-only             skip the offsite upload this time
#   sudo ./backup.sh --list                   list local backups
#   sudo ./backup.sh --restore FILE           restore a local backup
#   sudo ./backup.sh --offsite-setup          connect to the Storage Box (one time)
#   sudo ./backup.sh --offsite-list           list offsite snapshots
#   sudo ./backup.sh --offsite-check          verify the offsite backups
#   sudo ./backup.sh --offsite-restore [ID]   restore an offsite snapshot (default: latest)
#
# Local backups contain config/ only. Offsite snapshots contain config/ AND .env,
# encrypted with RESTIC_PASSWORD: keep that password in your password manager.

set -euo pipefail

cd "$(dirname "$0")"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
fail() { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

ask() {
  local answer
  read -r -p "    $1 [Y/n] " answer || return 1
  [[ ! "$answer" =~ ^[Nn] ]]
}

[[ -f .env ]] || fail ".env not found. Run ./setup.sh first."
# shellcheck disable=SC1091
source .env

CONFIG_ROOT=${CONFIG_ROOT:-./config}
BACKUP_DIR=${BACKUP_DIR:-./backups}
BACKUP_KEEP=${BACKUP_KEEP:-7}
OFFSITE_ENABLED=${OFFSITE_ENABLED:-false}
HETZNER_PATH=${HETZNER_PATH:-core-stack}
SSH_KEY=${OFFSITE_SSH_KEY:-/root/.ssh/hetzner-core-stack}
SNAPSHOT_FILE=core-stack.tar
SNAPSHOT_TAG=core-stack

# Logs, query history and downloaded filter lists that don't need restoring
EXCLUDES=(
  --exclude '*/logs'
  --exclude 'adguardhome/work/data/querylog.json*'
  --exclude 'adguardhome/work/data/filters'
)

# Replace KEY=value in .env, keeping the file's owner and permissions
# (this script runs as root; .env belongs to the user)
set_env() {
  local key=$1 value=$2 tmp
  tmp=$(mktemp)
  if grep -q "^${key}=" .env; then
    sed "s|^${key}=.*|${key}=${value}|" .env > "$tmp"
  else
    cat .env > "$tmp"; echo "${key}=${value}" >> "$tmp"
  fi
  cat "$tmp" > .env
  rm -f "$tmp"
}

ARGS="$*"
MODE=backup
STOP=true
OFFSITE=true
RESTORE_FILE=
SNAPSHOT_ID=latest
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-stop)         STOP=false ;;
    --local-only)      OFFSITE=false ;;
    --list)            MODE=list ;;
    --restore)         MODE=restore; RESTORE_FILE=${2:-}; shift ;;
    --offsite-setup)   MODE=offsite-setup ;;
    --offsite-list)    MODE=offsite-list ;;
    --offsite-check)   MODE=offsite-check ;;
    --offsite-restore) MODE=offsite-restore
                       if [[ -n "${2:-}" && "$2" != --* ]]; then SNAPSHOT_ID=$2; shift; fi ;;
    -h|--help)         sed -n '2,18p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

# Root-owned files (AdGuard Home, NPM, Tailscale) can't be read otherwise
if [[ "$MODE" != list && "$(uname -s)" == Linux && $EUID -ne 0 ]]; then
  fail "Run with sudo: sudo ./backup.sh ${ARGS}"
fi

# --- Stack control -------------------------------------------------

WAS_RUNNING=false
stop_stack() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found in PATH, so the stack can't be stopped. Continuing without."
    return 0
  fi
  if [[ -n "$(docker compose ps -q --status running 2>/dev/null)" ]]; then
    WAS_RUNNING=true
    info "Stopping the stack"
    docker compose stop
  fi
}

start_stack() {
  if [[ "$WAS_RUNNING" == true ]]; then
    info "Starting the stack again"
    docker compose start
    WAS_RUNNING=false
  fi
}

STAGING=
cleanup() {
  start_stack
  [[ -n "$STAGING" ]] && rm -rf "$STAGING"
  return 0
}
trap cleanup EXIT

# Move the current config aside and put the config from DIR in its place
swap_in_config() {
  local src=$1 aside=
  if [[ -d "$CONFIG_ROOT" ]]; then
    aside="${CONFIG_ROOT}.before-restore-$(date +%Y-%m-%d_%H%M%S)"
    mv "$CONFIG_ROOT" "$aside"
    info "Current config moved to ${aside}"
  fi
  mkdir -p "$(dirname "$CONFIG_ROOT")"
  mv "$src" "$CONFIG_ROOT"
  info "Restore done. Delete ${aside:-the old config} once everything works."
}

# --- Offsite (restic over SFTP to a Hetzner Storage Box) -------------

restic_env() {
  [[ -n "${HETZNER_USER:-}" && -n "${HETZNER_HOST:-}" ]] \
    || fail "Set HETZNER_USER and HETZNER_HOST in .env (see README, Offsite backups)."
  [[ -n "${RESTIC_PASSWORD:-}" ]] \
    || fail "RESTIC_PASSWORD is empty in .env. Run: sudo ./backup.sh --offsite-setup"
  command -v restic >/dev/null 2>&1 \
    || fail "restic isn't installed. Run: sudo ./backup.sh --offsite-setup"
  export RESTIC_REPOSITORY="sftp:${HETZNER_USER}@${HETZNER_HOST}:${HETZNER_PATH}"
  export RESTIC_PASSWORD
  SFTP_CMD="ssh -p 23 -i ${SSH_KEY} -o BatchMode=yes ${HETZNER_USER}@${HETZNER_HOST} -s sftp"
}

r() { restic -o sftp.command="$SFTP_CMD" "$@"; }

sftp_works() {
  echo pwd | sftp -P 23 -i "$SSH_KEY" -o BatchMode=yes -b - \
    "${HETZNER_USER}@${HETZNER_HOST}" >/dev/null 2>&1
}

offsite_setup() {
  [[ -n "${HETZNER_USER:-}" && -n "${HETZNER_HOST:-}" ]] \
    || fail "Set HETZNER_USER and HETZNER_HOST in .env first (see README, Offsite backups)."

  if ! command -v restic >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || fail "Install restic first: https://restic.net"
    ask "restic isn't installed. Install it with apt?" || fail "restic is required."
    apt-get install -y restic
  fi

  if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
    warn "RESTIC_PASSWORD is empty. It encrypts your offsite backups."
    ask "Generate a strong password and save it in .env?" \
      || fail "Set RESTIC_PASSWORD in .env yourself, then run this again."
    RESTIC_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
    set_env RESTIC_PASSWORD "$RESTIC_PASSWORD"
    warn "Saved as RESTIC_PASSWORD in .env. Copy it to your password manager NOW:"
    warn "without it, the offsite backups can never be restored."
  fi

  if [[ ! -f "$SSH_KEY" ]]; then
    info "Creating SSH key ${SSH_KEY}"
    mkdir -p "$(dirname "$SSH_KEY")" && chmod 700 "$(dirname "$SSH_KEY")"
    ssh-keygen -q -t ed25519 -N "" -C "core-stack@$(hostname)" -f "$SSH_KEY"
  fi

  if sftp_works; then
    info "SSH key already works on ${HETZNER_HOST}"
  else
    info "Installing the SSH key on the Storage Box."
    info "Confirm the host fingerprint and enter the Storage Box password once."
    ssh-copy-id -p 23 -s -i "${SSH_KEY}.pub" "${HETZNER_USER}@${HETZNER_HOST}"
    sftp_works || fail "Still can't log in with the key. Is SSH support enabled for this account?"
    info "SSH key works"
  fi

  restic_env
  if r cat config >/dev/null 2>&1; then
    info "Offsite repository already exists at ${HETZNER_PATH}"
  else
    info "Creating encrypted repository at ${HETZNER_PATH}"
    r init
  fi

  if [[ "$OFFSITE_ENABLED" != true ]] && ask "Upload offsite with every backup (OFFSITE_ENABLED=true)?"; then
    set_env OFFSITE_ENABLED true
  fi
  info "Offsite setup done. Make a first backup with: sudo ./backup.sh"
}

offsite_upload() {
  local staged=$1
  restic_env
  info "Uploading to ${HETZNER_HOST}:${HETZNER_PATH} (encrypted)"
  # Called in an `||` context, where set -e is off: check each step
  r backup --stdin --stdin-filename "$SNAPSHOT_FILE" --tag "$SNAPSHOT_TAG" \
    --host "$(hostname)" < "$staged" || return 1
  info "Applying offsite retention (daily ${OFFSITE_KEEP_DAILY:-7}, weekly ${OFFSITE_KEEP_WEEKLY:-4}, monthly ${OFFSITE_KEEP_MONTHLY:-6})"
  r forget --tag "$SNAPSHOT_TAG" --prune \
    --keep-daily "${OFFSITE_KEEP_DAILY:-7}" \
    --keep-weekly "${OFFSITE_KEEP_WEEKLY:-4}" \
    --keep-monthly "${OFFSITE_KEEP_MONTHLY:-6}" || return 1
}

# --- Modes ---------------------------------------------------------

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
    do_offsite=false
    if [[ "$OFFSITE" == true && "$OFFSITE_ENABLED" == true ]]; then
      restic_env   # fail early, before stopping anything
      do_offsite=true
    fi

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    file="${BACKUP_DIR}/config-$(date +%Y-%m-%d_%H%M%S).tar.gz"

    [[ "$STOP" == true ]] && stop_stack

    info "Writing ${file}"
    # Backups contain the Tailscale identity and certificates: owner only
    (umask 077 && tar czf "$file" "${EXCLUDES[@]}" \
      -C "$(dirname "$CONFIG_ROOT")" "$(basename "$CONFIG_ROOT")")
    info "Backup size: $(du -h "$file" | cut -f1)"

    if [[ "$do_offsite" == true ]]; then
      # Uncompressed, so restic can deduplicate between snapshots
      STAGING=$(mktemp -d)
      (umask 077 && tar cf "${STAGING}/${SNAPSHOT_FILE}" "${EXCLUDES[@]}" \
        -C "$(dirname "$CONFIG_ROOT")" "$(basename "$CONFIG_ROOT")" \
        -C "$PWD" .env)
    fi

    # Everything is packed: bring DNS back before the (slower) upload
    start_stack

    old=$(ls -1t "${BACKUP_DIR}"/config-*.tar.gz | tail -n +$((BACKUP_KEEP + 1)))
    if [[ -n "$old" ]]; then
      info "Removing local backups beyond the newest ${BACKUP_KEEP}"
      echo "$old" | while IFS= read -r f; do rm -f "$f"; echo "    removed $f"; done
    fi

    if [[ "$do_offsite" == true ]]; then
      offsite_upload "${STAGING}/${SNAPSHOT_FILE}" \
        || fail "Offsite upload failed. The local backup ${file} is fine."
    fi
    ;;

  restore)
    [[ -n "$RESTORE_FILE" ]] || fail "Usage: ./backup.sh --restore FILE (see ./backup.sh --list)"
    [[ -f "$RESTORE_FILE" ]] || fail "Backup not found: ${RESTORE_FILE}"

    warn "This replaces ${CONFIG_ROOT} with the contents of ${RESTORE_FILE}."
    read -r -p "    Continue? [y/N] " answer || answer=
    [[ "$answer" =~ ^[Yy] ]] || { info "Cancelled"; exit 0; }

    STAGING=$(mktemp -d)
    tar xpf "$RESTORE_FILE" -C "$STAGING"
    [[ -d "${STAGING}/$(basename "$CONFIG_ROOT")" ]] \
      || fail "${RESTORE_FILE} doesn't contain $(basename "$CONFIG_ROOT")/"
    stop_stack
    swap_in_config "${STAGING}/$(basename "$CONFIG_ROOT")"
    ;;

  offsite-setup)
    offsite_setup
    ;;

  offsite-list)
    restic_env
    r snapshots --tag "$SNAPSHOT_TAG"
    ;;

  offsite-check)
    restic_env
    info "Checking the offsite repository (reads a 5% sample of the data)"
    r check --read-data-subset=5%
    ;;

  offsite-restore)
    restic_env
    warn "This replaces ${CONFIG_ROOT} with snapshot '${SNAPSHOT_ID}' from ${HETZNER_HOST}."
    warn "The .env from the snapshot is saved as .env.from-backup (your .env stays)."
    read -r -p "    Continue? [y/N] " answer || answer=
    [[ "$answer" =~ ^[Yy] ]] || { info "Cancelled"; exit 0; }

    STAGING=$(mktemp -d)
    info "Downloading snapshot ${SNAPSHOT_ID}"
    r dump --tag "$SNAPSHOT_TAG" "$SNAPSHOT_ID" "/${SNAPSHOT_FILE}" > "${STAGING}/${SNAPSHOT_FILE}"
    mkdir "${STAGING}/x"
    tar xpf "${STAGING}/${SNAPSHOT_FILE}" -C "${STAGING}/x"
    [[ -d "${STAGING}/x/$(basename "$CONFIG_ROOT")" ]] \
      || fail "Snapshot doesn't contain $(basename "$CONFIG_ROOT")/"

    stop_stack
    swap_in_config "${STAGING}/x/$(basename "$CONFIG_ROOT")"
    if [[ -f "${STAGING}/x/.env" ]]; then
      cp "${STAGING}/x/.env" .env.from-backup
      chmod 600 .env.from-backup
      chown --reference=.env .env.from-backup 2>/dev/null || true
      info "Saved the snapshot's .env as .env.from-backup."
      info "Compare it with your .env; on a new server: mv .env.from-backup .env"
    fi
    ;;
esac
