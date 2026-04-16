#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_DIR="/opt/remnanode"
CERT_DIR="/etc/ssl/remnawave-node"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

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
  for var in DOMAIN_MAIL SERVER_DOMAIN PORT_NODE NODE_SECRET; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
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
  local sysctl_file="/etc/sysctl.d/99-remnawave-node-disable-ipv6.conf"

  log "Disabling IPv6 on the host"
  cat > "$sysctl_file" <<'EOF'
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
      SSL_CERT: /etc/ssl/remnawave-node/cert.pem
      SSL_KEY: /etc/ssl/remnawave-node/key.pem
    volumes:
      - /etc/ssl/remnawave-node:/etc/ssl/remnawave-node:ro
YAML
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
  require_cmd sysctl
  load_env
  require_vars
  validate_port
  DISABLE_IPV6="${DISABLE_IPV6:-true}"
  validate_bool "$DISABLE_IPV6"

  install_docker_if_missing
  configure_ufw
  install_acme_if_missing
  issue_certificate
  if [[ "$DISABLE_IPV6" == "true" ]]; then
    disable_ipv6
  else
    log "Skipping IPv6 disable because DISABLE_IPV6=false"
  fi
  write_compose
  start_stack

  log "Done. Logs: cd $COMPOSE_DIR && docker compose logs -f"
}

main "$@"
