#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
PANEL_DIR="/opt/remnawave"
PANEL_COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
PANEL_ENV_FILE="$PANEL_DIR/.env"
NGINX_DIR="$PANEL_DIR/nginx"
NGINX_CONF_FILE="$NGINX_DIR/nginx.conf"
NGINX_COMPOSE_FILE="$NGINX_DIR/docker-compose.yml"
PANEL_FULLCHAIN_FILE="$NGINX_DIR/fullchain.pem"
PANEL_PRIVKEY_FILE="$NGINX_DIR/privkey.key"
SUB_FULLCHAIN_FILE="$NGINX_DIR/subdomain_fullchain.pem"
SUB_PRIVKEY_FILE="$NGINX_DIR/subdomain_privkey.key"
SUBSCRIPTION_DIR="$PANEL_DIR/subscription"
SUBSCRIPTION_COMPOSE_FILE="$SUBSCRIPTION_DIR/docker-compose.yml"
SUBSCRIPTION_ENV_FILE="$SUBSCRIPTION_DIR/.env"
SUBSCRIPTION_APP_PORT=3010

log() { echo "[$(date '+%F %T')] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: sudo bash remnawave-panel/setup-subscription-page.sh"; }
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
  for var in PANEL_DOMAIN DOMAIN_MAIL SUBSCRIPTION_PAGE_DOMAIN REMNAWAVE_API_TOKEN; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required variables in $ENV_FILE: ${missing[*]}"
  fi
}

normalize_env() {
  APP_PORT="${APP_PORT:-3000}"
  CUSTOM_SUB_PREFIX="${CUSTOM_SUB_PREFIX:-}"
  MARZBAN_LEGACY_LINK_ENABLED="${MARZBAN_LEGACY_LINK_ENABLED:-false}"
  MARZBAN_LEGACY_SECRET_KEY="${MARZBAN_LEGACY_SECRET_KEY:-}"
  CADDY_AUTH_API_TOKEN="${CADDY_AUTH_API_TOKEN:-}"

  [[ "$APP_PORT" =~ ^[0-9]+$ ]] || fail "APP_PORT must be numeric"
  (( APP_PORT >= 1 && APP_PORT <= 65535 )) || fail "APP_PORT must be between 1 and 65535"
  [[ "$MARZBAN_LEGACY_LINK_ENABLED" == "true" || "$MARZBAN_LEGACY_LINK_ENABLED" == "false" ]] || fail "MARZBAN_LEGACY_LINK_ENABLED must be true or false"

  SUB_PUBLIC_DOMAIN="$SUBSCRIPTION_PAGE_DOMAIN"
  if [[ -n "$CUSTOM_SUB_PREFIX" ]]; then
    SUB_PUBLIC_DOMAIN="$SUB_PUBLIC_DOMAIN/$CUSTOM_SUB_PREFIX"
  fi
}

require_panel_setup() {
  [[ -f "$PANEL_COMPOSE_FILE" ]] || fail "Panel compose file not found: $PANEL_COMPOSE_FILE. Run setup-remnawave-panel.sh first."
  [[ -f "$PANEL_ENV_FILE" ]] || fail "Panel env file not found: $PANEL_ENV_FILE. Run setup-remnawave-panel.sh first."
  [[ -f "$PANEL_FULLCHAIN_FILE" && -f "$PANEL_PRIVKEY_FILE" ]] || fail "Panel TLS files not found in $NGINX_DIR. Run setup-remnawave-panel.sh first."
}

install_base_packages() {
  log "Installing required packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl openssl ufw cron socat
}

configure_ufw() {
  log "Ensuring 443/tcp and 8443/tcp are open in UFW"
  ufw allow "443/tcp"
  ufw allow "8443/tcp"
  ufw --force enable
  ufw reload || true
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

configure_panel_sub_public_domain() {
  log "Updating SUB_PUBLIC_DOMAIN in $PANEL_ENV_FILE"
  set_env_value SUB_PUBLIC_DOMAIN "$SUB_PUBLIC_DOMAIN" "$PANEL_ENV_FILE"
}

prepare_subscription_files() {
  log "Writing bundled subscription page files"
  install -d -m 0755 "$SUBSCRIPTION_DIR"

  cat > "$SUBSCRIPTION_COMPOSE_FILE" <<YAML
services:
  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    env_file:
      - .env
    ports:
      - "127.0.0.1:${SUBSCRIPTION_APP_PORT}:${SUBSCRIPTION_APP_PORT}"
    networks:
      - remnawave-network

networks:
  remnawave-network:
    driver: bridge
    external: true
YAML

  cat > "$SUBSCRIPTION_ENV_FILE" <<EOF
APP_PORT=${SUBSCRIPTION_APP_PORT}
REMNAWAVE_PANEL_URL=http://remnawave:${APP_PORT}
REMNAWAVE_API_TOKEN=${REMNAWAVE_API_TOKEN}
CUSTOM_SUB_PREFIX=${CUSTOM_SUB_PREFIX}
MARZBAN_LEGACY_LINK_ENABLED=${MARZBAN_LEGACY_LINK_ENABLED}
MARZBAN_LEGACY_SECRET_KEY=${MARZBAN_LEGACY_SECRET_KEY}
CADDY_AUTH_API_TOKEN=${CADDY_AUTH_API_TOKEN}
EOF
}

issue_subscription_certificate() {
  export HOME="/root"
  export PATH="$HOME/.acme.sh:$PATH"

  install -d -m 0755 "$NGINX_DIR"

  if [[ -s "$SUB_FULLCHAIN_FILE" && -s "$SUB_PRIVKEY_FILE" ]]; then
    log "Existing subscription TLS certificate files were found in $NGINX_DIR"
    return
  fi

  log "Issuing TLS certificate for $SUBSCRIPTION_PAGE_DOMAIN with acme.sh"
  "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$SUBSCRIPTION_PAGE_DOMAIN" \
    --key-file "$SUB_PRIVKEY_FILE" \
    --fullchain-file "$SUB_FULLCHAIN_FILE" \
    --alpn \
    --tlsport 8443
}

write_nginx_files() {
  log "Writing combined Nginx configuration for panel and subscription page"

  cat > "$NGINX_CONF_FILE" <<EOF
upstream remnawave {
    server remnawave:${APP_PORT};
}
upstream remnawave-subscription-page {
    server remnawave-subscription-page:${SUBSCRIPTION_APP_PORT};
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
    server_name ${SUBSCRIPTION_PAGE_DOMAIN};

    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    location / {
        proxy_http_version 1.1;
        proxy_pass http://remnawave-subscription-page;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # SSL Configuration (Mozilla Intermediate Guidelines)
    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets    off;
    ssl_certificate "/etc/nginx/ssl/subdomain_fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/subdomain_privkey.key";
    ssl_trusted_certificate "/etc/nginx/ssl/subdomain_fullchain.pem";
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
      - ./subdomain_fullchain.pem:/etc/nginx/ssl/subdomain_fullchain.pem:ro
      - ./subdomain_privkey.key:/etc/nginx/ssl/subdomain_privkey.key:ro
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

restart_panel_container() {
  log "Recreating Remnawave panel container to apply SUB_PUBLIC_DOMAIN"
  (
    cd "$PANEL_DIR"
    docker compose up -d remnawave-db remnawave-redis
    docker compose up -d --force-recreate remnawave
  )

  wait_for_container remnawave-db 120
  wait_for_container remnawave-redis 120
  wait_for_container remnawave 180
}

start_subscription_stack() {
  log "Starting bundled subscription page container"
  (
    cd "$SUBSCRIPTION_DIR"
    docker compose up -d
  )

  wait_for_container remnawave-subscription-page 120
}

restart_nginx_stack() {
  log "Recreating Nginx with subscription page configuration"
  (
    cd "$NGINX_DIR"
    docker compose up -d --force-recreate remnawave-nginx
  )

  wait_for_container remnawave-nginx 60
}

verify_local_subscription_endpoint() {
  local status_code

  status_code="$(curl -ksS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${SUBSCRIPTION_APP_PORT}/" || true)"
  if [[ "$status_code" =~ ^[234][0-9][0-9]$ ]]; then
    log "Local subscription page endpoint is reachable with HTTP status $status_code"
  else
    fail "Subscription page endpoint on 127.0.0.1:${SUBSCRIPTION_APP_PORT} is not reachable"
  fi
}

main() {
  require_root
  load_env
  require_vars
  normalize_env
  require_panel_setup
  install_base_packages
  require_cmd curl
  require_cmd docker
  require_cmd ufw
  require_cmd openssl
  require_cmd socat
  configure_ufw
  install_acme_if_missing
  configure_panel_sub_public_domain
  prepare_subscription_files
  issue_subscription_certificate
  write_nginx_files
  restart_panel_container
  start_subscription_stack
  restart_nginx_stack
  verify_local_subscription_endpoint

  log "Bundled subscription page is deployed"
  log "Subscription page domain: https://$SUBSCRIPTION_PAGE_DOMAIN"
  log "Subscription public domain in panel env: $SUB_PUBLIC_DOMAIN"
}

main "$@"
