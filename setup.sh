#!/usr/bin/env bash
# Setup script for the core stack (AdGuard Home, Homepage, Cloudflare Tunnel,
# Tailscale). Meant for a Linux server.
#
# Usage: ./setup.sh [--no-start | --update]
#   --no-start   prepare .env, folders, config and host settings, but don't start
#   --update     pull the latest images, recreate changed containers, prune old images

set -euo pipefail

cd "$(dirname "$0")"

MODE=start
for arg in "$@"; do
  case "$arg" in
    --no-start) MODE=prepare ;;
    --update)   MODE=update ;;
    -h|--help)  sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
fail() { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# ask "question" -> 0 for yes (Enter = yes), 1 for no.
# Without a terminal (EOF) the answer is no, so nothing changes unattended.
ask() {
  local answer
  read -r -p "    $1 [Y/n] " answer || return 1
  [[ ! "$answer" =~ ^[Nn] ]]
}

# Replace KEY=value in .env (portable across macOS/BSD and GNU sed)
set_env() {
  local key=$1 value=$2 tmp
  tmp=$(mktemp)
  sed "s|^${key}=.*|${key}=${value}|" .env > "$tmp" && mv "$tmp" .env
}

# Append keys from .env.example that are missing in .env
sync_env() {
  local line key added=0
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z0-9_]+)= ]] || continue
    key=${BASH_REMATCH[1]}
    if ! grep -q "^${key}=" .env; then
      [[ $added -eq 0 ]] && printf '\n# Added by setup.sh from .env.example\n' >> .env
      echo "$line" >> .env
      info "Added missing ${key} to .env"
      added=1
    fi
  done < .env.example
}

load_env() {
  # shellcheck disable=SC1091
  source .env
}

profile_enabled() {
  [[ ",${COMPOSE_PROFILES:-}," == *",$1,"* ]]
}

is_linux() { [[ "$(uname -s)" == Linux ]]; }

# --- Checks and fixes ----------------------------------------------

# Suggest SERVER_IP and LAN_SUBNET from the default route
check_network() {
  is_linux && command -v ip >/dev/null 2>&1 || return 0
  local route ip dev subnet
  route=$(ip -4 route get 1.1.1.1 2>/dev/null) || return 0
  ip=$(awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' <<< "$route")
  dev=$(awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' <<< "$route")
  subnet=$(ip -4 route show dev "$dev" scope link proto kernel 2>/dev/null | awk '{print $1; exit}')

  if [[ -n "$ip" && "$ip" != "${SERVER_IP:-}" ]]; then
    warn ".env has SERVER_IP=${SERVER_IP:-unset}, this server's LAN IP looks like ${ip}"
    if ask "Set SERVER_IP=${ip}?"; then set_env SERVER_IP "$ip"; info "Updated SERVER_IP"; fi
  fi
  if [[ -n "$subnet" && "$subnet" != "${LAN_SUBNET:-}" ]]; then
    warn ".env has LAN_SUBNET=${LAN_SUBNET:-unset}, this network looks like ${subnet}"
    if ask "Set LAN_SUBNET=${subnet}?"; then set_env LAN_SUBNET "$subnet"; info "Updated LAN_SUBNET"; fi
  fi
}

check_ids() {
  local uid gid
  uid=$(id -u); gid=$(id -g)
  if [[ "${PUID:-}" != "$uid" || "${PGID:-}" != "$gid" ]]; then
    warn ".env has PUID=${PUID:-unset} PGID=${PGID:-unset}, current user is ${uid}:${gid}"
    if ask "Update .env to match the current user?"; then
      set_env PUID "$uid"; set_env PGID "$gid"
      info "Updated PUID/PGID in .env"
    fi
  fi
}

# Enabled profiles need their secrets
check_profiles() {
  if profile_enabled tunnel && [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
    fail "Profile 'tunnel' is enabled but CLOUDFLARE_TUNNEL_TOKEN is empty.
    Add the token to .env (see README), or remove 'tunnel' from COMPOSE_PROFILES."
  fi
  if profile_enabled tailscale && [[ -z "${TS_AUTHKEY:-}" ]]; then
    local state="${CONFIG_ROOT}/tailscale"
    # State dir is root-owned once Tailscale ran; unreadable means it exists
    if [[ -d "$state" && ! -r "$state" ]] || [[ -n "$(ls -A "$state" 2>/dev/null)" ]]; then
      return 0
    fi
    fail "Profile 'tailscale' is enabled but TS_AUTHKEY is empty and Tailscale hasn't logged in yet.
    Add an auth key to .env (see README), or remove 'tailscale' from COMPOSE_PROFILES."
  fi
}

# Port 53 is taken by systemd-resolved's stub listener on Ubuntu/Debian
check_port53() {
  is_linux || return 0
  [[ "${DNS_BIND_IP:-0.0.0.0}" == 0.0.0.0 ]] || return 0
  command -v ss >/dev/null 2>&1 || return 0
  # Our own AdGuard Home holding the port is fine
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx adguardhome; then return 0; fi

  local listeners
  listeners=$(ss -H -lnu 2>/dev/null | awk '{print $4}' | grep -E ':53$' || true)
  [[ -z "$listeners" ]] && return 0

  # systemd-resolved listens on 127.0.0.53 (shown as 127.0.0.53%lo:53) and 127.0.0.54
  local stub='^127\.0\.0\.5[34](%[[:alnum:]]+)?:53$'
  if grep -qE "$stub" <<< "$listeners" \
     && [[ -z "$(grep -vE "$stub" <<< "$listeners")" ]]; then
    warn "Port 53 is used by systemd-resolved's stub listener. AdGuard Home needs it."
    warn "Fix: turn off the stub listener. The server keeps using your router's DNS."
    if ask "Apply this fix now (uses sudo)?"; then
      sudo mkdir -p /etc/systemd/resolved.conf.d
      printf '[Resolve]\nDNSStubListener=no\n' \
        | sudo tee /etc/systemd/resolved.conf.d/adguardhome.conf >/dev/null
      if [[ ! -L /etc/resolv.conf || "$(readlink /etc/resolv.conf)" != /run/systemd/resolve/resolv.conf ]]; then
        sudo mv /etc/resolv.conf /etc/resolv.conf.backup
        sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
      fi
      sudo systemctl reload-or-restart systemd-resolved
      info "Stub listener disabled (old /etc/resolv.conf saved as /etc/resolv.conf.backup)"
    else
      fail "Free port 53 first, or set DNS_BIND_IP=${SERVER_IP} in .env."
    fi
  else
    fail "Port 53 is in use by another DNS server: ${listeners//$'\n'/ }
    Stop it (e.g. dnsmasq), or set DNS_BIND_IP to an address it doesn't use."
  fi
}

# The reverse proxy needs host ports 80 and 443; Homepage used to have 80
check_proxy_ports() {
  profile_enabled proxy || return 0
  case "${HOMEPAGE_PORT:-}" in
    80|443) ;;
    *) return 0 ;;
  esac

  warn "The reverse proxy needs port ${HOMEPAGE_PORT}, but Homepage uses it (HOMEPAGE_PORT=${HOMEPAGE_PORT})."
  warn "Homepage stays reachable as http://${SERVER_NAME:-server.home} through the proxy."
  if ask "Move Homepage to port 3002?"; then
    set_env HOMEPAGE_PORT 3002
    HOMEPAGE_PORT=3002
    info "Updated HOMEPAGE_PORT to 3002"
    # Free the old port now, so the proxy can start in the same run
    docker compose stop homepage >/dev/null 2>&1 || true
  else
    fail "Change HOMEPAGE_PORT in .env, or remove 'proxy' from COMPOSE_PROFILES."
  fi
}

# Subnet routing over Tailscale needs IP forwarding on the host
check_ip_forward() {
  is_linux || return 0
  profile_enabled tailscale || return 0
  [[ -n "${LAN_SUBNET:-}" ]] || return 0
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == 1 ]] && return 0

  warn "IP forwarding is off. Tailscale devices can't reach other devices on ${LAN_SUBNET}."
  if ask "Enable IP forwarding permanently (uses sudo)?"; then
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
      | sudo tee /etc/sysctl.d/99-tailscale.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null
    info "IP forwarding enabled"
  else
    warn "Skipped. Only the server itself will be reachable over Tailscale."
  fi
}

# Create folders and seed the Homepage config
prepare_folders() {
  info "Creating folders under ${CONFIG_ROOT}"
  mkdir -p "${CONFIG_ROOT}/adguardhome/work" "${CONFIG_ROOT}/adguardhome/conf" \
    "${CONFIG_ROOT}/homepage" "${CONFIG_ROOT}/tailscale" \
    "${CONFIG_ROOT}/npm/data" "${CONFIG_ROOT}/npm/letsencrypt"

  local f
  for f in homepage/*.yaml; do
    if [[ ! -f "${CONFIG_ROOT}/homepage/$(basename "$f")" ]]; then
      cp "$f" "${CONFIG_ROOT}/homepage/"
      info "Created ${CONFIG_ROOT}/homepage/$(basename "$f") from template"
    fi
  done
}

print_summary() {
  local home="http://${SERVER_IP}"
  [[ "${HOMEPAGE_PORT}" != 80 ]] && home="${home}:${HOMEPAGE_PORT}"
  echo
  echo "Stack is running:"
  echo "  Homepage       ${home}"
  if [[ -f "${CONFIG_ROOT}/adguardhome/conf/AdGuardHome.yaml" ]]; then
    echo "  AdGuard Home   http://${SERVER_IP}:${ADGUARD_WEB_PORT}"
  else
    echo "  AdGuard Home   http://${SERVER_IP}:${ADGUARD_SETUP_PORT}  (first-run wizard)"
  fi
  echo "  DNS server     ${SERVER_IP}:53"
  profile_enabled proxy     && echo "  Proxy admin    http://${SERVER_IP}:${NPM_ADMIN_PORT}  (Nginx Proxy Manager)"
  profile_enabled tunnel    && echo "  Cloudflare     tunnel running, manage it at https://one.dash.cloudflare.com/"
  profile_enabled tailscale && echo "  Tailscale      '${TS_HOSTNAME}', manage it at https://login.tailscale.com/admin/machines"
  if profile_enabled tailscale && [[ -n "${LAN_SUBNET:-}" ]]; then
    echo
    warn "Approve the subnet route ${LAN_SUBNET} for '${TS_HOSTNAME}' in the Tailscale admin console."
  fi
  if profile_enabled tailscale && [[ -n "${TS_AUTHKEY:-}" ]]; then
    warn "Once Tailscale shows as connected, you can clear TS_AUTHKEY in .env."
  fi
}

# --- Prerequisites -------------------------------------------------
info "Checking prerequisites"
if ! is_linux; then
  warn "This stack is meant for a Linux server. On $(uname -s), AdGuard Home on"
  warn "port 53 and Tailscale host networking won't work as intended."
  ask "Continue anyway?" || exit 1
fi
command -v docker >/dev/null 2>&1 \
  || fail "Docker not found. Install Docker Engine first (see README.md)."
docker compose version >/dev/null 2>&1 \
  || fail "Docker Compose v2 not found ('docker compose'). Install the compose plugin."
docker info >/dev/null 2>&1 \
  || fail "Can't reach the Docker daemon. Is it running, and is your user in the 'docker' group?"
[[ -f docker-compose.yml ]] || fail "docker-compose.yml not found in $(pwd)"
[[ -f .env.example ]] || fail ".env.example not found in $(pwd)"

# --- .env ----------------------------------------------------------
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  info "Created .env from .env.example (readable only by you: it will hold secrets)"
else
  sync_env
fi
load_env

# --- Update --------------------------------------------------------
if [[ "$MODE" == update ]]; then
  check_proxy_ports
  prepare_folders
  docker compose config --quiet || fail "Compose file is invalid"
  info "Pulling latest images"
  docker compose pull
  info "Recreating containers with new images"
  docker compose up -d --remove-orphans
  info "Removing old images"
  docker image prune -f
  print_summary
  exit 0
fi

# --- Install -------------------------------------------------------
check_ids
check_network
load_env
check_profiles
check_proxy_ports
check_port53
check_ip_forward
prepare_folders

info "Validating docker-compose.yml"
docker compose config --quiet || fail "Compose file is invalid"

if [[ "$MODE" == prepare ]]; then
  info "Setup done. Start the stack with: docker compose up -d"
  exit 0
fi

info "Pulling images"
docker compose pull

info "Starting containers"
docker compose up -d

print_summary
echo
echo "Next: follow \"First-time configuration\" in README.md."
