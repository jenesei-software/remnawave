#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
PANEL_DIR="/opt/remnawave"
COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
DEPLOY_ENV_FILE="$PANEL_DIR/.env"
NGINX_DIR="$PANEL_DIR/nginx"
NGINX_CONF_FILE="$NGINX_DIR/nginx.conf"
NGINX_COMPOSE_FILE="$NGINX_DIR/docker-compose.yml"
NGINX_FULLCHAIN_FILE="$NGINX_DIR/fullchain.pem"
NGINX_PRIVKEY_FILE="$NGINX_DIR/privkey.key"
PANEL_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml"
PANEL_ENV_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: sudo bash remnawave-panel/setup-remnawave-panel.sh"; }
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
  for var in PANEL_DOMAIN DOMAIN_MAIL; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required variables in $ENV_FILE: ${missing[*]}"
  fi
}

validate_port_var() {
  local name="$1"
  local value="${!name:-}"
  [[ -z "$value" ]] && return 0
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be numeric"
  (( value >= 1 && value <= 65535 )) || fail "$name must be between 1 and 65535"
}

validate_bool_var() {
  local name="$1"
  local value="${!name:-}"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name must be true or false"
}

normalize_env() {
  CUSTOM_SUB_PREFIX="${CUSTOM_SUB_PREFIX:-}"
  SUBSCRIPTION_PAGE_DOMAIN="${SUBSCRIPTION_PAGE_DOMAIN:-}"

  if [[ -z "${SUB_PUBLIC_DOMAIN:-}" && -n "$SUBSCRIPTION_PAGE_DOMAIN" ]]; then
    SUB_PUBLIC_DOMAIN="$SUBSCRIPTION_PAGE_DOMAIN"
    if [[ -n "$CUSTOM_SUB_PREFIX" ]]; then
      SUB_PUBLIC_DOMAIN="$SUB_PUBLIC_DOMAIN/$CUSTOM_SUB_PREFIX"
    fi
  fi

  SUB_PUBLIC_DOMAIN="${SUB_PUBLIC_DOMAIN:-$PANEL_DOMAIN/api/sub}"
  APP_PORT="${APP_PORT:-3000}"
  METRICS_PORT="${METRICS_PORT:-3001}"
  API_INSTANCES="${API_INSTANCES:-1}"
  IS_DOCS_ENABLED="${IS_DOCS_ENABLED:-false}"
  SWAGGER_PATH="${SWAGGER_PATH:-/docs}"
  SCALAR_PATH="${SCALAR_PATH:-/scalar}"
  METRICS_USER="${METRICS_USER:-admin}"
  POSTGRES_USER="${POSTGRES_USER:-postgres}"
  POSTGRES_DB="${POSTGRES_DB:-postgres}"

  validate_port_var APP_PORT
  validate_port_var METRICS_PORT
  validate_bool_var IS_DOCS_ENABLED
}

install_base_packages() {
  log "Installing base packages required for Remnawave Panel"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl openssl ufw cron socat
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker and docker compose are already installed"
    return
  fi

  log "Installing Docker using the official Docker installation script"
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
}

configure_ufw() {
  log "Opening 443/tcp and 8443/tcp in UFW"
  ufw allow "443/tcp"
  ufw allow "8443/tcp"
  ufw --force enable
  ufw reload || true
}

download_if_missing() {
  local url="$1"
  local target="$2"

  if [[ -f "$target" ]]; then
    log "Keeping existing file: $target"
    return
  fi

  log "Downloading $(basename "$target")"
  curl -fsSL "$url" -o "$target"
}

prepare_panel_files() {
  install -d -m 0755 "$PANEL_DIR"
  download_if_missing "$PANEL_COMPOSE_URL" "$COMPOSE_FILE"
  download_if_missing "$PANEL_ENV_URL" "$DEPLOY_ENV_FILE"
}

install_acme_if_missing() {
  export HOME="/root"
  export PATH="$HOME/.acme.sh:$PATH"

  if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
    log "acme.sh is already installed"
    return
  fi

  log "Installing acme.sh"
  curl https://get.acme.sh | sh -s email="$DOMAIN_MAIL"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[|&]/\\&/g'
}

set_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"
  local escaped

  escaped="$(escape_sed_replacement "$value")"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

get_env_value() {
  local key="$1"
  local file="$2"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

ensure_random_hex_if_placeholder() {
  local key="$1"
  local bytes="$2"
  local current

  current="$(get_env_value "$key" "$DEPLOY_ENV_FILE")"
  if [[ -z "$current" || "$current" == "change_me" || "$current" == "admin" ]]; then
    set_env_value "$key" "$(openssl rand -hex "$bytes")" "$DEPLOY_ENV_FILE"
    log "Generated value for $key"
  fi
}

configure_database_env() {
  local postgres_password

  postgres_password="$(get_env_value POSTGRES_PASSWORD "$DEPLOY_ENV_FILE")"
  if [[ -z "$postgres_password" || "$postgres_password" == "postgres" || "$postgres_password" == "change_me" ]]; then
    postgres_password="$(openssl rand -hex 24)"
    log "Generated a new Postgres password"
  else
    log "Keeping existing Postgres password"
  fi

  set_env_value POSTGRES_USER "$POSTGRES_USER" "$DEPLOY_ENV_FILE"
  set_env_value POSTGRES_PASSWORD "$postgres_password" "$DEPLOY_ENV_FILE"
  set_env_value POSTGRES_DB "$POSTGRES_DB" "$DEPLOY_ENV_FILE"
  set_env_value DATABASE_URL "\"postgresql://${POSTGRES_USER}:${postgres_password}@remnawave-db:5432/${POSTGRES_DB}\"" "$DEPLOY_ENV_FILE"
}

configure_panel_env() {
  set_env_value APP_PORT "$APP_PORT" "$DEPLOY_ENV_FILE"
  set_env_value METRICS_PORT "$METRICS_PORT" "$DEPLOY_ENV_FILE"
  set_env_value API_INSTANCES "$API_INSTANCES" "$DEPLOY_ENV_FILE"
  set_env_value PANEL_DOMAIN "$PANEL_DOMAIN" "$DEPLOY_ENV_FILE"
  set_env_value FRONT_END_DOMAIN "$PANEL_DOMAIN" "$DEPLOY_ENV_FILE"
  set_env_value SUB_PUBLIC_DOMAIN "$SUB_PUBLIC_DOMAIN" "$DEPLOY_ENV_FILE"
  set_env_value IS_DOCS_ENABLED "$IS_DOCS_ENABLED" "$DEPLOY_ENV_FILE"
  set_env_value SWAGGER_PATH "$SWAGGER_PATH" "$DEPLOY_ENV_FILE"
  set_env_value SCALAR_PATH "$SCALAR_PATH" "$DEPLOY_ENV_FILE"
  set_env_value METRICS_USER "$METRICS_USER" "$DEPLOY_ENV_FILE"
}

issue_certificate() {
  export HOME="/root"
  export PATH="$HOME/.acme.sh:$PATH"

  install -d -m 0755 "$NGINX_DIR"

  if [[ -s "$NGINX_FULLCHAIN_FILE" && -s "$NGINX_PRIVKEY_FILE" ]]; then
    log "Existing TLS certificate files were found in $NGINX_DIR"
    return
  fi

  log "Issuing TLS certificate for $PANEL_DOMAIN with acme.sh"
  "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$PANEL_DOMAIN" \
    --key-file "$NGINX_PRIVKEY_FILE" \
    --fullchain-file "$NGINX_FULLCHAIN_FILE" \
    --alpn \
    --tlsport 8443
}

write_nginx_files() {
  install -d -m 0755 "$NGINX_DIR"

  cat > "$NGINX_CONF_FILE" <<EOF
upstream remnawave {
    server remnawave:${APP_PORT};
}

server {
    server_name ${PANEL_DOMAIN};
    listen 443 ssl reuseport;
    listen [::]:443 ssl reuseport;
    http2 on;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    # SSL Configuration (Mozilla Intermediate Guidelines)
    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;
    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_stapling           on;
    ssl_stapling_verify    on;
    resolver               1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 208.67.222.222 208.67.220.220 valid=60s;
    resolver_timeout       2s;
    # Gzip Compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;
    gzip_types
        application/atom+xml
        application/geo+json
        application/javascript
        application/x-javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rdf+xml
        application/rss+xml
        application/xhtml+xml
        application/xml
        font/eot
        font/otf
        font/ttf
        image/svg+xml
        text/css
        text/javascript
        text/plain
        text/xml;
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_reject_handshake on;
}
EOF

  cat > "$NGINX_COMPOSE_FILE" <<YAML
services:
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./fullchain.pem:/etc/nginx/ssl/fullchain.pem:ro
      - ./privkey.key:/etc/nginx/ssl/privkey.key:ro
    restart: always
    ports:
      - "0.0.0.0:443:443"
    networks:
      - remnawave-network

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: true
YAML
}

wait_for_container() {
  local container="$1"
  local timeout="${2:-120}"
  local elapsed=0
  local status

  while (( elapsed < timeout )); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    case "$status" in
      healthy|running)
        log "Container is ready: $container ($status)"
        return 0
        ;;
      unhealthy|exited|dead)
        fail "Container failed: $container ($status)"
        ;;
    esac

    sleep 2
    elapsed=$((elapsed + 2))
  done

  fail "Timed out waiting for container: $container"
}

start_panel_stack() {
  log "Starting Remnawave Panel stack"
  (
    cd "$PANEL_DIR"
    docker compose up -d
  )

  wait_for_container remnawave-db 120
  wait_for_container remnawave-redis 120
  wait_for_container remnawave 180
}

start_nginx_stack() {
  log "Starting Nginx reverse proxy"
  (
    cd "$NGINX_DIR"
    docker compose up -d
  )

  wait_for_container remnawave-nginx 60
}

verify_health_endpoint() {
  log "Checking local health endpoint"
  curl -fsS "http://127.0.0.1:${METRICS_PORT}/health" >/dev/null
}

main() {
  require_root
  load_env
  require_vars
  normalize_env
  install_base_packages
  install_docker_if_missing
  require_cmd curl
  require_cmd openssl
  require_cmd docker
  require_cmd ufw
  require_cmd socat
  configure_ufw
  prepare_panel_files
  install_acme_if_missing
  ensure_random_hex_if_placeholder JWT_AUTH_SECRET 64
  ensure_random_hex_if_placeholder JWT_API_TOKENS_SECRET 64
  ensure_random_hex_if_placeholder METRICS_PASS 64
  ensure_random_hex_if_placeholder WEBHOOK_SECRET_HEADER 32
  configure_database_env
  configure_panel_env
  issue_certificate
  write_nginx_files
  start_panel_stack
  start_nginx_stack
  verify_health_endpoint

  log "Remnawave Panel is deployed"
  log "Open https://$PANEL_DOMAIN in your browser and create the first super-admin account."
  log "Then create an API token in Remnawave Dashboard -> Settings -> API Tokens."
  log "After that, run: sudo bash remnawave-panel/setup-subscription-page.sh"
  log "Panel files: $PANEL_DIR"
  log "Nginx files: $NGINX_DIR"
}

main "$@"
