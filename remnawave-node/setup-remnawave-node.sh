#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_DIR="/opt/remnanode"
CERT_DIR="/etc/ssl/remnawave-node"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
IPV6_DISABLE_SYSCTL_FILE="/etc/sysctl.d/99-remnawave-node-disable-ipv6.conf"
IPV6_ENABLE_SYSCTL_FILE="/etc/sysctl.d/99-remnawave-node-enable-ipv6.conf"
IPV6_LEGACY_DISABLE_SYSCTL_FILE="/etc/sysctl.d/11-disable-ipv6.conf"
UFW_DEFAULTS_FILE="/etc/default/ufw"

LOG_COLOR='\033[1;36m'
LOG_RESET='\033[0m'

timestamp() { date '+%F %T'; }
log_line() {
  local level="$1"
  shift
  printf '%b[%s] %-7s%b %s\n' "$LOG_COLOR" "$(timestamp)" "$level" "$LOG_RESET" "$*"
}

log() { log_line "INFO" "$*"; }
fail() { log_line "ERROR" "$*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: sudo bash remnawave-node/setup-remnawave-node.sh"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"; }

load_env() {
  [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

require_vars() {
  local missing=()
  for var in PORT_NODE NODE_SECRET; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if [[ -n "${SERVER_DOMAIN:-}" && -z "${DOMAIN_MAIL:-}" ]]; then
    missing+=("DOMAIN_MAIL")
  fi
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required variables in .env: ${missing[*]}"
  fi
}

validate_port() {
  [[ "$PORT_NODE" =~ ^[0-9]+$ ]] || fail "PORT_NODE must be numeric"
  (( PORT_NODE >= 1 && PORT_NODE <= 65535 )) || fail "PORT_NODE must be between 1 and 65535"
}

validate_bool() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "Boolean value must be true or false"
}

disable_ipv6() {
  log "Disabling IPv6 on the host"
  rm -f "$IPV6_ENABLE_SYSCTL_FILE"
  cat > "$IPV6_DISABLE_SYSCTL_FILE" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

  sysctl --system >/dev/null

  [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == "1" ]] || fail "Failed to disable IPv6 for net.ipv6.conf.all.disable_ipv6"
  [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6)" == "1" ]] || fail "Failed to disable IPv6 for net.ipv6.conf.default.disable_ipv6"
  [[ "$(sysctl -n net.ipv6.conf.lo.disable_ipv6)" == "1" ]] || fail "Failed to disable IPv6 for net.ipv6.conf.lo.disable_ipv6"

  log "IPv6 has been disabled"
}

ensure_ufw_ipv6_enabled() {
  if [[ ! -f "$UFW_DEFAULTS_FILE" ]]; then
    log "UFW defaults file not found, skipping UFW IPv6 setting"
    return
  fi

  if grep -qE '^IPV6=' "$UFW_DEFAULTS_FILE"; then
    sed -i -E 's/^IPV6=.*/IPV6=yes/' "$UFW_DEFAULTS_FILE"
  else
    printf '\nIPV6=yes\n' >> "$UFW_DEFAULTS_FILE"
  fi
}

resolve_ipv6_interface() {
  if [[ -n "${IPV6_INTERFACE:-}" ]]; then
    printf '%s\n' "$IPV6_INTERFACE"
    return
  fi

  local iface
  iface="$(ip -o -6 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
  if [[ -z "$iface" ]]; then
    iface="$(ip -o -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
  fi
  if [[ -z "$iface" && -d /sys/class/net/eth0 ]]; then
    iface="eth0"
  fi

  [[ -n "$iface" ]] || fail "Could not detect network interface for IPv6. Set IPV6_INTERFACE in .env."
  printf '%s\n' "$iface"
}

ipv6_enable_settings() {
  local iface="$1"
  printf '%s\n' \
    "net.ipv6.conf.all.disable_ipv6=0" \
    "net.ipv6.conf.default.disable_ipv6=0" \
    "net.ipv6.conf.lo.disable_ipv6=0" \
    "net.ipv6.conf.${iface}.disable_ipv6=0" \
    "net.ipv6.conf.${iface}.accept_ra=2" \
    "net.ipv6.conf.all.forwarding=1" \
    "net.ipv6.conf.all.addr_gen_mode=0" \
    "net.ipv6.conf.${iface}.use_tempaddr=0"
}

apply_ipv6_enable_settings() {
  local iface="$1"
  local setting expected pair

  while IFS= read -r pair; do
    setting="${pair%%=*}"
    expected="${pair#*=}"
    sysctl -w "$setting=$expected" >/dev/null || fail "Failed to set $setting=$expected"
  done < <(ipv6_enable_settings "$iface")
}

verify_ipv6_enable_settings() {
  local iface="$1"
  local setting expected pair value

  while IFS= read -r pair; do
    setting="${pair%%=*}"
    expected="${pair#*=}"
    value="$(sysctl -n "$setting" 2>/dev/null || echo unknown)"
    [[ "$value" == "$expected" ]] || fail "Failed to verify $setting=$expected, current value is $value"
  done < <(ipv6_enable_settings "$iface")
}

restart_network_for_ipv6() {
  local restarted=false

  if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    log "Restarting systemd-networkd to apply IPv6 settings"
    systemctl restart systemd-networkd || log "Could not restart systemd-networkd"
    restarted=true
  fi

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    log "Restarting NetworkManager to apply IPv6 settings"
    systemctl restart NetworkManager || log "Could not restart NetworkManager"
    restarted=true
  fi

  if [[ "$restarted" == "false" ]]; then
    log "No supported network service is active, skipping network restart"
  fi
}

enable_ipv6() {
  local iface

  log "Enabling IPv6 on the host"
  iface="$(resolve_ipv6_interface)"
  log "Using IPv6 network interface: $iface"

  rm -f "$IPV6_DISABLE_SYSCTL_FILE" "$IPV6_LEGACY_DISABLE_SYSCTL_FILE"
  cat > "$IPV6_ENABLE_SYSCTL_FILE" <<EOF
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.${iface}.disable_ipv6 = 0
net.ipv6.conf.${iface}.accept_ra = 2
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.addr_gen_mode = 0
net.ipv6.conf.${iface}.use_tempaddr = 0
EOF

  ensure_ufw_ipv6_enabled
  sysctl --system >/dev/null || true

  apply_ipv6_enable_settings "$iface"
  restart_network_for_ipv6
  apply_ipv6_enable_settings "$iface"
  verify_ipv6_enable_settings "$iface"

  [[ -f /proc/net/if_inet6 ]] || fail "IPv6 kernel support is not active. Check kernel boot parameters such as ipv6.disable=1"

  log "IPv6 has been enabled"
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker and docker compose are already installed"
    return
  fi

  log "Installing Docker"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a
  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${VERSION_CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
}

configure_ufw() {
  log "Opening 80/tcp, 443/tcp, 8443/tcp, the node port, and inbound ports in UFW"
  ufw allow "80/tcp"
  ufw allow "443/tcp"
  ufw allow "$PORT_NODE/tcp"
  ufw allow "8443/tcp"

  if [[ -n "${PORT_ARRAY_INBOUNDS:-}" ]]; then
    IFS=',' read -r -a ports <<< "$PORT_ARRAY_INBOUNDS"
    for raw_port in "${ports[@]}"; do
      port="$(echo "$raw_port" | xargs)"
      [[ -z "$port" ]] && continue
      [[ "$port" =~ ^[0-9]+$ ]] || fail "Invalid port in PORT_ARRAY_INBOUNDS: $port"
      ufw allow "$port/tcp"
    done
  fi

  ufw reload || true
}

install_acme_if_missing() {
  if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
    log "acme.sh is already installed"
    return
  fi

  log "Installing acme.sh"
  curl https://get.acme.sh | sh
}

issue_certificate() {
  mkdir -p "$CERT_DIR"
  export HOME="/root"
  export PATH="$HOME/.acme.sh:$PATH"

  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
  "$HOME/.acme.sh/acme.sh" --register-account -m "$DOMAIN_MAIL" || true

  log "Issuing a certificate for $SERVER_DOMAIN"
  "$HOME/.acme.sh/acme.sh" --issue -d "$SERVER_DOMAIN" --standalone --force
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$SERVER_DOMAIN" \
    --key-file "$CERT_DIR/key.pem" \
    --fullchain-file "$CERT_DIR/cert.pem"
}

ensure_certificate() {
  if [[ -n "${SERVER_DOMAIN:-}" ]]; then
    install_acme_if_missing
    issue_certificate
  else
    log "SERVER_DOMAIN is not set; skipping TLS certificate issuance"
  fi
}

write_compose() {
  local image="${REMNAWAVE_NODE_IMAGE:-remnawave/node:latest}"

  mkdir -p "$COMPOSE_DIR"
  cat > "$COMPOSE_FILE" <<YAML
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${image}
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      NODE_PORT: "${PORT_NODE}"
      SECRET_KEY: "${NODE_SECRET}"
YAML

  if [[ -n "${SERVER_DOMAIN:-}" ]]; then
    cat >> "$COMPOSE_FILE" <<YAML
      SSL_CERT: /etc/ssl/remnawave-node/cert.pem
      SSL_KEY: /etc/ssl/remnawave-node/key.pem
    volumes:
      - /etc/ssl/remnawave-node:/etc/ssl/remnawave-node:ro
YAML
  fi
}

start_stack() {
  cd "$COMPOSE_DIR"
  docker compose up -d
  docker compose ps
}

main() {
  require_root
  require_cmd curl
  require_cmd ufw
  require_cmd gpg
  require_cmd grep
  require_cmd sed
  require_cmd sysctl
  load_env
  require_vars
  validate_port
  DISABLE_IPV6="${DISABLE_IPV6:-true}"
  validate_bool "$DISABLE_IPV6"

  if [[ "$DISABLE_IPV6" == "false" ]]; then
    enable_ipv6
  fi
  install_docker_if_missing
  configure_ufw
  ensure_certificate
  if [[ "$DISABLE_IPV6" == "true" ]]; then
    disable_ipv6
  fi
  write_compose
  start_stack

  log "Done. Logs: cd $COMPOSE_DIR && docker compose logs -f"
}

main "$@"
