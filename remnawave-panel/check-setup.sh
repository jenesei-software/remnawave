#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
PANEL_DIR="/opt/remnawave"
DEPLOY_ENV_FILE="$PANEL_DIR/.env"
NGINX_DIR="$PANEL_DIR/nginx"
SUBSCRIPTION_DIR="$PANEL_DIR/subscription"

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

load_env_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  fi
}

load_env() {
  load_env_file "$ENV_FILE"
  load_env_file "$DEPLOY_ENV_FILE"
  PANEL_DOMAIN="${PANEL_DOMAIN:-${FRONT_END_DOMAIN:-}}"
  SUBSCRIPTION_PAGE_DOMAIN="${SUBSCRIPTION_PAGE_DOMAIN:-}"
}

subscription_expected() {
  [[ -n "${SUBSCRIPTION_PAGE_DOMAIN:-}" || -f "$SUBSCRIPTION_DIR/docker-compose.yml" ]]
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
  check_cmd docker
  check_cmd ufw
  check_cmd ss
  check_cmd curl

  systemctl is-active --quiet docker && ok "Docker service: active" || err "Docker service: NOT active"
}

check_files() {
  section "Files"
  [[ -f "$PANEL_DIR/docker-compose.yml" ]] && ok "Found $PANEL_DIR/docker-compose.yml" || err "Missing $PANEL_DIR/docker-compose.yml"
  [[ -f "$DEPLOY_ENV_FILE" ]] && ok "Found $DEPLOY_ENV_FILE" || err "Missing $DEPLOY_ENV_FILE"
  [[ -f "$NGINX_DIR/docker-compose.yml" ]] && ok "Found $NGINX_DIR/docker-compose.yml" || err "Missing $NGINX_DIR/docker-compose.yml"
  [[ -f "$NGINX_DIR/nginx.conf" ]] && ok "Found $NGINX_DIR/nginx.conf" || err "Missing $NGINX_DIR/nginx.conf"
  [[ -f "$NGINX_DIR/fullchain.pem" ]] && ok "Found $NGINX_DIR/fullchain.pem" || err "Missing $NGINX_DIR/fullchain.pem"
  [[ -f "$NGINX_DIR/privkey.key" ]] && ok "Found $NGINX_DIR/privkey.key" || err "Missing $NGINX_DIR/privkey.key"

  if subscription_expected; then
    [[ -f "$SUBSCRIPTION_DIR/docker-compose.yml" ]] && ok "Found $SUBSCRIPTION_DIR/docker-compose.yml" || err "Missing $SUBSCRIPTION_DIR/docker-compose.yml"
    [[ -f "$SUBSCRIPTION_DIR/.env" ]] && ok "Found $SUBSCRIPTION_DIR/.env" || err "Missing $SUBSCRIPTION_DIR/.env"
    [[ -f "$NGINX_DIR/subdomain_fullchain.pem" ]] && ok "Found $NGINX_DIR/subdomain_fullchain.pem" || err "Missing $NGINX_DIR/subdomain_fullchain.pem"
    [[ -f "$NGINX_DIR/subdomain_privkey.key" ]] && ok "Found $NGINX_DIR/subdomain_privkey.key" || err "Missing $NGINX_DIR/subdomain_privkey.key"
  fi
}

check_containers() {
  section "Containers"

  for container in remnawave remnawave-db remnawave-redis remnawave-nginx; do
    if docker ps --format '{{.Names}}' | grep -qx "$container"; then
      ok "Container is running: $container"
    else
      err "Container is not running: $container"
    fi
  done

  if docker network inspect remnawave-network >/dev/null 2>&1; then
    ok "Docker network exists: remnawave-network"
  else
    err "Docker network missing: remnawave-network"
  fi

  if subscription_expected; then
    if docker ps --format '{{.Names}}' | grep -qx 'remnawave-subscription-page'; then
      ok "Container is running: remnawave-subscription-page"
    else
      err "Container is not running: remnawave-subscription-page"
    fi
  fi
}

check_ports() {
  section "Ports and bindings"

  local panel_port="${APP_PORT:-3000}"
  local metrics_port="${METRICS_PORT:-3001}"

  if ss -tln | grep -q "127.0.0.1:${panel_port}"; then
    ok "Panel is bound to 127.0.0.1:${panel_port}"
  else
    warn "Panel binding 127.0.0.1:${panel_port} was not detected"
  fi

  if ss -tln | grep -q "127.0.0.1:${metrics_port}"; then
    ok "Metrics are bound to 127.0.0.1:${metrics_port}"
  else
    warn "Metrics binding 127.0.0.1:${metrics_port} was not detected"
  fi

  if ss -tln | grep -q ':443 '; then
    ok "Port 443 is listening"
  else
    warn "Port 443 is not listening"
  fi

  if ufw status | grep -q "8443/tcp"; then
    ok "UFW allows 8443/tcp for acme.sh"
  else
    warn "UFW does not show 8443/tcp for acme.sh"
  fi

  echo
  info "Listening TCP ports:"
  ss -tln || true

  if subscription_expected; then
    if ss -tln | grep -q '127.0.0.1:3010'; then
      ok "Subscription page is bound to 127.0.0.1:3010"
    else
      warn "Subscription page binding 127.0.0.1:3010 was not detected"
    fi
  fi
}

check_http() {
  section "Health checks"
  local status_code

  if curl -fsS "http://127.0.0.1:${METRICS_PORT:-3001}/health" >/dev/null; then
    ok "Local Remnawave health endpoint is reachable"
  else
    err "Local Remnawave health endpoint is not reachable"
  fi

  if [[ -n "${PANEL_DOMAIN:-}" ]]; then
    if curl -kfsS --resolve "${PANEL_DOMAIN}:443:127.0.0.1" "https://${PANEL_DOMAIN}" >/dev/null; then
      ok "HTTPS endpoint responds for ${PANEL_DOMAIN}"
    else
      warn "HTTPS endpoint did not respond for ${PANEL_DOMAIN}"
    fi
  else
    warn "PANEL_DOMAIN is not set, skipping HTTPS virtual host check"
  fi

  if subscription_expected; then
    status_code="$(curl -ksS -o /dev/null -w '%{http_code}' --resolve "${SUBSCRIPTION_PAGE_DOMAIN}:443:127.0.0.1" "https://${SUBSCRIPTION_PAGE_DOMAIN}/" || true)"
    if [[ "$status_code" =~ ^[234][0-9][0-9]$ ]]; then
      ok "HTTPS endpoint responds for ${SUBSCRIPTION_PAGE_DOMAIN} with HTTP status ${status_code}"
    else
      warn "HTTPS endpoint did not respond as expected for ${SUBSCRIPTION_PAGE_DOMAIN}"
    fi
  fi
}

check_ufw() {
  section "UFW"

  if ufw status | grep -q "Status: active"; then
    ok "UFW is active"
  else
    err "UFW is not active"
  fi

  if ufw status | grep -q "443/tcp"; then
    ok "UFW allows 443/tcp"
  else
    warn "UFW does not show 443/tcp"
  fi

  if ufw status | grep -q "8443/tcp"; then
    ok "UFW allows 8443/tcp"
  else
    warn "UFW does not show 8443/tcp"
  fi

  echo
  info "All UFW rules:"
  ufw status numbered || true
}

main() {
  load_env
  check_system
  check_files
  check_containers
  check_ports
  check_http
  check_ufw
}

main "$@"
