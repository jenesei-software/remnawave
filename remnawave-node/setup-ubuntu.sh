#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти скрипт от root: sudo bash remnawave-node/setup-ubuntu.sh"; }
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
  for var in ROOT_PASSWORD USER_NAME USER_PASSWORD PORT_SSH SSH_PUB SERVER_NAME; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Не заполнены переменные в .env: ${missing[*]}"
  fi
}

validate_port() {
  [[ "$PORT_SSH" =~ ^[0-9]+$ ]] || fail "PORT_SSH должен быть числом"
  (( PORT_SSH >= 10001 && PORT_SSH <= 65535 )) || fail "PORT_SSH должен быть в диапазоне 10001-65535"
}

create_or_update_user() {
  if id "$USER_NAME" >/dev/null 2>&1; then
    log "Пользователь $USER_NAME уже существует"
  else
    log "Создаю пользователя $USER_NAME"
    adduser --disabled-password --gecos "" "$USER_NAME"
  fi

  echo "$USER_NAME:$USER_PASSWORD" | chpasswd
  usermod -aG sudo "$USER_NAME"
}

setup_ssh_key() {
  local ssh_dir="/home/$USER_NAME/.ssh"
  local auth_keys="$ssh_dir/authorized_keys"

  mkdir -p "$ssh_dir"
  touch "$auth_keys"
  chmod 700 "$ssh_dir"
  chmod 600 "$auth_keys"
  chown -R "$USER_NAME:$USER_NAME" "$ssh_dir"

  if ! grep -Fqx "$SSH_PUB" "$auth_keys"; then
    log "Добавляю публичный SSH ключ для $USER_NAME"
    printf '%s\n' "$SSH_PUB" >> "$auth_keys"
  else
    log "SSH ключ уже добавлен"
  fi
}

configure_ssh() {
  local sshd_config="/etc/ssh/sshd_config"
  cp "$sshd_config" "${sshd_config}.bak.$(date +%s)"

  sed -i -E "s/^#?Port .*/Port $PORT_SSH/" "$sshd_config"
  sed -i -E "s/^#?PermitRootLogin .*/PermitRootLogin no/" "$sshd_config"

  if grep -qE '^#?PasswordAuthentication ' "$sshd_config"; then
    sed -i -E 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' "$sshd_config"
  else
    printf '\nPasswordAuthentication no\n' >> "$sshd_config"
  fi

  if grep -qE '^#?PermitEmptyPasswords ' "$sshd_config"; then
    sed -i -E 's/^#?PermitEmptyPasswords .*/PermitEmptyPasswords no/' "$sshd_config"
  else
    printf 'PermitEmptyPasswords no\n' >> "$sshd_config"
  fi

  sshd -t
  systemctl restart sshd 2>/dev/null || systemctl restart ssh
}

install_packages() {
  log "Обновляю систему и устанавливаю базовые пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt upgrade -y
  apt install -y nano fail2ban ufw less ca-certificates curl gnupg
}

configure_hostname() {
  log "Устанавливаю hostname: $SERVER_NAME"
  hostnamectl set-hostname "$SERVER_NAME"
}

configure_root_password() {
  log "Обновляю пароль root"
  echo "root:$ROOT_PASSWORD" | chpasswd
}

configure_ufw() {
  log "Настраиваю UFW"
  ufw allow "$PORT_SSH/tcp"
  ufw --force enable
  ufw reload
}

ensure_fail2ban() {
  systemctl enable fail2ban
  systemctl restart fail2ban
}

main() {
  require_root
  require_cmd sed
  require_cmd grep
  load_env
  require_vars
  validate_port

  configure_hostname
  configure_root_password
  create_or_update_user
  setup_ssh_key
  install_packages
  configure_ssh
  ensure_fail2ban
  configure_ufw

  log "Готово. Подключайся так: ssh $USER_NAME@<SERVER_IP> -p $PORT_SSH"
  log "Перед выходом обязательно проверь, что новый SSH доступ работает в отдельной сессии."
}

main "$@"
