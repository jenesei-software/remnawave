#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_DIR="/opt/remnanode"
CERT_DIR="/etc/ssl/remnawave-node"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "[INFO] $*"; }
section() { echo; echo "==== $* ===="; }

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  else
    warn "Environment file not found: $ENV_FILE"
  fi

  DISABLE_IPV6="${DISABLE_IPV6:-true}"
}

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    ok "Command found: $1"
  else
    err "Command not found: $1"
  fi
}

check_system() {
  section "Base system"
  check_cmd ssh
  check_cmd ufw
  check_cmd fail2ban-client
  check_cmd docker
  check_cmd ss
  check_cmd sysctl

  systemctl is-active --quiet fail2ban && ok "Service fail2ban: active" || err "Service fail2ban: NOT active"
  systemctl is-active --quiet docker && ok "Service docker: active" || err "Service docker: NOT active"
  systemctl is-active --quiet ssh && ok "Service ssh: active" || systemctl is-active --quiet sshd && ok "Service sshd: active" || err "Service ssh/sshd: NOT active"
}

check_ipv6() {
  section "IPv6"

  if [[ "$DISABLE_IPV6" == "true" ]]; then
    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" == "1" ]] && \
       [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)" == "1" ]] && \
       [[ "$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo 0)" == "1" ]]; then
      ok "IPv6 is disabled on the host"
    else
      warn "IPv6 is still enabled on the host, but DISABLE_IPV6=true in .env"
    fi
  else
    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" == "1" ]] && \
       [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)" == "1" ]] && \
       [[ "$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo 0)" == "1" ]]; then
      ok "IPv6 is disabled on the host, even though DISABLE_IPV6=false"
    else
      ok "IPv6 is enabled on the host as configured by DISABLE_IPV6=false"
    fi
  fi
}

check_ssh() {
  section "SSH"
  local sshd_config="/etc/ssh/sshd_config"
  [[ -f "$sshd_config" ]] || { err "File not found: $sshd_config"; return; }

  if [[ -n "${PORT_SSH:-}" ]] && grep -Eq "^Port ${PORT_SSH}$" "$sshd_config"; then
    ok "SSH port is configured: $PORT_SSH"
  else
    warn "Could not confirm PORT_SSH from .env"
  fi

  grep -Eq '^PermitRootLogin no$' "$sshd_config" && ok "Root login is disabled" || warn "PermitRootLogin no not found"
  grep -Eq '^PasswordAuthentication no$' "$sshd_config" && ok "Password authentication is disabled" || warn "PasswordAuthentication no not found"
}

check_ufw() {
  section "UFW"
  if ufw status | grep -q "Status: active"; then
    ok "UFW is active"
  else
    err "UFW is not active"
  fi

  if [[ -n "${PORT_SSH:-}" ]] && ufw status | grep -q "$PORT_SSH/tcp"; then
    ok "SSH port is open in UFW: $PORT_SSH/tcp"
  else
    warn "SSH port was not found in UFW"
  fi

  if [[ -n "${PORT_NODE:-}" ]] && ufw status | grep -q "$PORT_NODE/tcp"; then
    ok "Node port is open in UFW: $PORT_NODE/tcp"
  else
    warn "Node port was not found in UFW"
  fi

  if ufw status | grep -q "80/tcp"; then
    ok "HTTP port is open in UFW: 80/tcp"
  else
    warn "HTTP port was not found in UFW: 80/tcp"
  fi

  if ufw status | grep -q "443/tcp"; then
    ok "HTTPS port is open in UFW: 443/tcp"
  else
    warn "HTTPS port was not found in UFW: 443/tcp"
  fi

  if ufw status | grep -q "8443/tcp"; then
    ok "acme.sh port is open in UFW: 8443/tcp"
  else
    warn "acme.sh port was not found in UFW: 8443/tcp"
  fi

  if [[ -n "${PORT_ARRAY_INBOUNDS:-}" ]]; then
    IFS=',' read -r -a ports <<< "$PORT_ARRAY_INBOUNDS"
    for raw_port in "${ports[@]}"; do
      port="$(echo "$raw_port" | xargs)"
      [[ -z "$port" ]] && continue
      if ufw status | grep -q "$port/tcp"; then
        ok "Inbound port is open: $port/tcp"
      else
        warn "Inbound port was not found: $port/tcp"
      fi
    done
  fi

  echo
  info "All UFW rules:"
  ufw status numbered || true
}

check_listening_ports() {
  section "Listening ports"
  ss -tulpn || warn "Could not list listening ports with ss"
}

check_certs() {
  section "Certificates"
  [[ -f "$CERT_DIR/cert.pem" ]] && ok "Found cert.pem" || err "Missing $CERT_DIR/cert.pem"
  [[ -f "$CERT_DIR/key.pem" ]] && ok "Found key.pem" || err "Missing $CERT_DIR/key.pem"
}

check_docker_compose() {
  section "Docker / Remnawave Node"
  [[ -f "$COMPOSE_DIR/docker-compose.yml" ]] && ok "Found docker-compose.yml" || err "Missing $COMPOSE_DIR/docker-compose.yml"

  if docker ps --format '{{.Names}}' | grep -qx 'remnanode'; then
    ok "Container remnanode is running"
  else
    err "Container remnanode is not running"
  fi

  if command -v docker >/dev/null 2>&1 && [[ -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
    (cd "$COMPOSE_DIR" && docker compose ps) || warn "Could not run docker compose ps"
  fi
}

main() {
  load_env
  check_system
  check_ipv6
  check_ssh
  check_ufw
  check_listening_ports
  check_certs
  check_docker_compose
}

main "$@"
