#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
COMPOSE_DIR="/opt/remnanode"
CERT_DIR="/etc/ssl/remnawave-node"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти скрипт от root: sudo bash remnawave-node/setup-remnawave-node.sh"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Не найдена команда: $1"; }

load_env() {
  [[ -f "$ENV_FILE" ]] || fail "Файл окружения не найден: $ENV_FILE"
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
    fail "Не заполнены переменные в .env: ${missing[*]}"
  fi
}

validate_port() {
  [[ "$PORT_NODE" =~ ^[0-9]+$ ]] || fail "PORT_NODE должен быть числом"
  (( PORT_NODE >= 1 && PORT_NODE <= 65535 )) || fail "PORT_NODE должен быть в диапазоне 1-65535"
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker и docker compose уже установлены"
    return
  fi

  log "Устанавливаю Docker"
  apt update
  apt install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  
  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${VERSION_CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
}

configure_ufw() {
  log "Открываю порт панели, 8443/tcp для acme.sh и inbound порты в UFW"
  ufw allow "$PORT_NODE/tcp"
  ufw allow "8443/tcp"

  if [[ -n "${PORT_ARRAY_INBOUNDS:-}" ]]; then
    IFS=',' read -r -a ports <<< "$PORT_ARRAY_INBOUNDS"
    for raw_port in "${ports[@]}"; do
      port="$(echo "$raw_port" | xargs)"
      [[ -z "$port" ]] && continue
      [[ "$port" =~ ^[0-9]+$ ]] || fail "Некорректный порт в PORT_ARRAY_INBOUNDS: $port"
      ufw allow "$port/tcp"
    done
  fi

  ufw reload || true
}

install_acme_if_missing() {
  if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
    log "acme.sh уже установлен"
    return
  fi

  log "Устанавливаю acme.sh"
  curl https://get.acme.sh | sh
}

issue_certificate() {
  mkdir -p "$CERT_DIR"
  export HOME="/root"
  export PATH="$HOME/.acme.sh:$PATH"

  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
  "$HOME/.acme.sh/acme.sh" --register-account -m "$DOMAIN_MAIL" || true

  log "Выпускаю сертификат для $SERVER_DOMAIN (UFW уже открыл 8443/tcp для acme.sh)"
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
  load_env
  require_vars
  validate_port

  install_docker_if_missing
  configure_ufw
  install_acme_if_missing
  issue_certificate
  write_compose
  start_stack

  log "Готово. Проверка логов: cd $COMPOSE_DIR && docker compose logs -f"
}

main "$@"
