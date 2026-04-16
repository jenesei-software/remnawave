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
    warn "Файл .env не найден: $ENV_FILE"
  fi
}

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then ok "Команда найдена: $1"; else err "Команда не найдена: $1"; fi
}

check_system() {
  section "Базовая система"
  check_cmd ssh
  check_cmd ufw
  check_cmd fail2ban-client
  check_cmd docker
  check_cmd ss

  systemctl is-active --quiet fail2ban && ok "Сервис fail2ban: active" || err "Сервис fail2ban: NOT active"
  systemctl is-active --quiet docker && ok "Сервис docker: active" || err "Сервис docker: NOT active"
  systemctl is-active --quiet ssh && ok "Сервис ssh: active" || systemctl is-active --quiet sshd && ok "Сервис sshd: active" || err "Сервис ssh/sshd: NOT active"
}

check_ssh() {
  section "SSH"
  local sshd_config="/etc/ssh/sshd_config"
  [[ -f "$sshd_config" ]] || { err "Не найден $sshd_config"; return; }

  if [[ -n "${PORT_SSH:-}" ]] && grep -Eq "^Port ${PORT_SSH}$" "$sshd_config"; then
    ok "SSH порт настроен: $PORT_SSH"
  else
    warn "Не удалось подтвердить PORT_SSH из .env"
  fi

  grep -Eq '^PermitRootLogin no$' "$sshd_config" && ok "Root login отключен" || warn "PermitRootLogin no не найден"
  grep -Eq '^PasswordAuthentication no$' "$sshd_config" && ok "PasswordAuthentication отключен" || warn "PasswordAuthentication no не найден"
}

check_ufw() {
  section "UFW"
  if ufw status | grep -q "Status: active"; then
    ok "UFW активен"
  else
    err "UFW не активен"
  fi

  if [[ -n "${PORT_SSH:-}" ]] && ufw status | grep -q "$PORT_SSH/tcp"; then
    ok "SSH порт открыт в UFW: $PORT_SSH/tcp"
  else
    warn "SSH порт не найден в UFW"
  fi

  if [[ -n "${PORT_NODE:-}" ]] && ufw status | grep -q "$PORT_NODE/tcp"; then
    ok "Порт ноды открыт в UFW: $PORT_NODE/tcp"
  else
    warn "Порт ноды не найден в UFW"
  fi

  if ufw status | grep -q "80/tcp"; then
    ok "HTTP порт открыт в UFW: 80/tcp"
  else
    warn "HTTP порт не найден в UFW: 80/tcp"
  fi

  if ufw status | grep -q "443/tcp"; then
    ok "HTTPS порт открыт в UFW: 443/tcp"
  else
    warn "HTTPS порт не найден в UFW: 443/tcp"
  fi

  if ufw status | grep -q "8443/tcp"; then
    ok "Порт acme.sh открыт в UFW: 8443/tcp"
  else
    warn "Порт acme.sh не найден в UFW: 8443/tcp"
  fi

  if [[ -n "${PORT_ARRAY_INBOUNDS:-}" ]]; then
    IFS=',' read -r -a ports <<< "$PORT_ARRAY_INBOUNDS"
    for raw_port in "${ports[@]}"; do
      port="$(echo "$raw_port" | xargs)"
      [[ -z "$port" ]] && continue
      if ufw status | grep -q "$port/tcp"; then
        ok "Inbound порт открыт: $port/tcp"
      else
        warn "Inbound порт не найден: $port/tcp"
      fi
    done
  fi

  echo
  info "Все открытые правила UFW:"
  ufw status numbered || true
}

check_listening_ports() {
  section "Слушающие порты на сервере"
  ss -tulpn || warn "Не удалось получить список слушающих портов через ss"
}

check_certs() {
  section "Сертификаты"
  [[ -f "$CERT_DIR/cert.pem" ]] && ok "Найден cert.pem" || err "Не найден $CERT_DIR/cert.pem"
  [[ -f "$CERT_DIR/key.pem" ]] && ok "Найден key.pem" || err "Не найден $CERT_DIR/key.pem"
}

check_docker_compose() {
  section "Docker / Remnawave Node"
  [[ -f "$COMPOSE_DIR/docker-compose.yml" ]] && ok "Найден docker-compose.yml" || err "Не найден $COMPOSE_DIR/docker-compose.yml"

  if docker ps --format '{{.Names}}' | grep -qx 'remnanode'; then
    ok "Контейнер remnanode запущен"
  else
    err "Контейнер remnanode не запущен"
  fi

  if command -v docker >/dev/null 2>&1 && [[ -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
    (cd "$COMPOSE_DIR" && docker compose ps) || warn "Не удалось получить docker compose ps"
  fi
}

main() {
  load_env
  check_system
  check_ssh
  check_ufw
  check_listening_ports
  check_certs
  check_docker_compose
}

main "$@"
