#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_DIR="/opt/remnanode"
CERT_DIR="/etc/ssl/remnawave-node"
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

ok() { log_line "OK" "$*"; }
warn() { log_line "WARN" "$*"; }
err() { log_line "ERROR" "$*"; }
info() { log_line "INFO" "$*"; }
section() { echo; log_line "SECTION" "$*"; }

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

resolve_ipv6_interface() {
  if [[ -n "${IPV6_INTERFACE:-}" ]]; then
    printf '%s\n' "$IPV6_INTERFACE"
    return
  fi

  local iface
  if command -v ip >/dev/null 2>&1; then
    iface="$(ip -o -6 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
    if [[ -z "$iface" ]]; then
      iface="$(ip -o -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | sed -n '1p' || true)"
    fi
  fi

  if [[ -z "${iface:-}" && -d /sys/class/net/eth0 ]]; then
    iface="eth0"
  fi

  [[ -n "${iface:-}" ]] || return 1
  printf '%s\n' "$iface"
}

check_sysctl_value() {
  local setting="$1"
  local expected="$2"
  local value

  value="$(sysctl -n "$setting" 2>/dev/null || echo unknown)"
  if [[ "$value" == "$expected" ]]; then
    ok "$setting=$expected"
  else
    err "$setting expected $expected, got $value"
  fi
}

check_system() {
  section "Base system"
  check_cmd ssh
  check_cmd ufw
  check_cmd fail2ban-client
  check_cmd docker
  check_cmd ip
  check_cmd ss
  check_cmd sysctl

  systemctl is-active --quiet fail2ban && ok "Service fail2ban: active" || err "Service fail2ban: NOT active"
  systemctl is-active --quiet docker && ok "Service docker: active" || err "Service docker: NOT active"
  systemctl is-active --quiet ssh && ok "Service ssh: active" || systemctl is-active --quiet sshd && ok "Service sshd: active" || err "Service ssh/sshd: NOT active"
}

check_ipv6() {
  section "IPv6"
  local ipv6_all ipv6_default ipv6_lo
  local iface

  ipv6_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unknown)"
  ipv6_default="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo unknown)"
  ipv6_lo="$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo unknown)"

  if [[ "$DISABLE_IPV6" == "true" ]]; then
    if [[ "$ipv6_all" == "1" && "$ipv6_default" == "1" && "$ipv6_lo" == "1" ]]; then
      ok "IPv6 is disabled on the host"
    else
      warn "IPv6 is still enabled on the host, but DISABLE_IPV6=true in .env"
    fi
  else
    if iface="$(resolve_ipv6_interface)"; then
      ok "IPv6 network interface: $iface"
    else
      err "Could not detect IPv6 network interface. Set IPV6_INTERFACE in .env."
    fi

    check_sysctl_value net.ipv6.conf.all.disable_ipv6 0
    check_sysctl_value net.ipv6.conf.default.disable_ipv6 0
    check_sysctl_value net.ipv6.conf.lo.disable_ipv6 0
    check_sysctl_value net.ipv6.conf.all.forwarding 1
    check_sysctl_value net.ipv6.conf.all.addr_gen_mode 0

    if [[ -n "${iface:-}" ]]; then
      check_sysctl_value "net.ipv6.conf.${iface}.disable_ipv6" 0
      check_sysctl_value "net.ipv6.conf.${iface}.accept_ra" 2
      check_sysctl_value "net.ipv6.conf.${iface}.use_tempaddr" 0
    fi

    if [[ -f /proc/net/if_inet6 ]]; then
      ok "IPv6 kernel support is active"
    else
      err "IPv6 kernel support is not active. Check kernel boot parameters such as ipv6.disable=1"
    fi

    if [[ -f "$IPV6_ENABLE_SYSCTL_FILE" ]]; then
      ok "IPv6 enable config is present: $IPV6_ENABLE_SYSCTL_FILE"
    else
      err "IPv6 enable config is missing: $IPV6_ENABLE_SYSCTL_FILE"
    fi

    if [[ -f "$IPV6_DISABLE_SYSCTL_FILE" ]]; then
      err "IPv6 disable config still exists: $IPV6_DISABLE_SYSCTL_FILE"
    else
      ok "No Remnawave IPv6 disable config is present"
    fi

    if [[ -f "$IPV6_LEGACY_DISABLE_SYSCTL_FILE" ]]; then
      err "Legacy IPv6 disable config still exists: $IPV6_LEGACY_DISABLE_SYSCTL_FILE"
    else
      ok "No legacy IPv6 disable config is present"
    fi

    if [[ -f "$UFW_DEFAULTS_FILE" ]]; then
      if grep -qE '^IPV6=yes$' "$UFW_DEFAULTS_FILE"; then
        ok "UFW IPv6 support is enabled"
      else
        err "UFW IPv6 support is not enabled in $UFW_DEFAULTS_FILE"
      fi
    else
      warn "UFW defaults file was not found: $UFW_DEFAULTS_FILE"
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
  if [[ -z "${SERVER_DOMAIN:-}" ]]; then
    info "SERVER_DOMAIN is not set; certificate files are not required"
    return
  fi

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
