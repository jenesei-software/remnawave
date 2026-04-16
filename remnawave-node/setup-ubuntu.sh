#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: sudo bash remnawave-node/setup-ubuntu.sh"; }
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
  for var in ROOT_PASSWORD USER_NAME USER_PASSWORD PORT_SSH SSH_PUB SERVER_NAME; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Missing required variables in .env: ${missing[*]}"
  fi
}

validate_port() {
  [[ "$PORT_SSH" =~ ^[0-9]+$ ]] || fail "PORT_SSH must be numeric"
  (( PORT_SSH >= 10001 && PORT_SSH <= 65535 )) || fail "PORT_SSH must be between 10001 and 65535"
}

validate_bool() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "Boolean value must be true or false"
}

check_ipv6_status() {
  local ipv6_all ipv6_default

  ipv6_all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unknown)"
  ipv6_default="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo unknown)"

  if [[ "$DISABLE_IPV6" == "true" ]]; then
    if [[ "$ipv6_all" == "1" && "$ipv6_default" == "1" ]]; then
      log "IPv6 is already disabled on this server"
    else
      log "IPv6 is currently enabled. remnawave-node/setup-remnawave-node.sh will disable it before starting the node"
    fi
  else
    if [[ "$ipv6_all" == "1" && "$ipv6_default" == "1" ]]; then
      log "IPv6 is already disabled on this server, but DISABLE_IPV6=false in .env"
    else
      log "IPv6 will stay enabled because DISABLE_IPV6=false in .env"
    fi
  fi
}

create_or_update_user() {
  if id "$USER_NAME" >/dev/null 2>&1; then
    log "User already exists: $USER_NAME"
  else
    log "Creating user: $USER_NAME"
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
    log "Adding SSH public key for $USER_NAME"
    printf '%s\n' "$SSH_PUB" >> "$auth_keys"
  else
    log "SSH public key is already present"
  fi
}

configure_ssh() {
  local sshd_config="/etc/ssh/sshd_config"
  local sshd_dropin_dir="/etc/ssh/sshd_config.d"
  local sshd_dropin_file="$sshd_dropin_dir/99-remnawave.conf"

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

  install -d -m 0755 "$sshd_dropin_dir"
  cat > "$sshd_dropin_file" <<EOF
Port $PORT_SSH
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
EOF

  install -d -m 0755 /run/sshd
  sshd -t

  if systemctl list-unit-files --type=socket | grep -q '^ssh.socket'; then
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ssh.socket.d/override.conf || true
    systemctl daemon-reload
  fi

  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart sshd 2>/dev/null || systemctl restart ssh

  if ss -tln "( sport = :$PORT_SSH )" | grep -q LISTEN; then
    log "SSHD is listening on the new port: $PORT_SSH"
  else
    fail "SSHD is not listening on port $PORT_SSH after restart"
  fi
}

install_packages() {
  log "Updating the system and installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a
  apt-get update
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade
  apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    install nano fail2ban ufw less ca-certificates curl gnupg
}

configure_hostname() {
  log "Setting hostname: $SERVER_NAME"
  hostnamectl set-hostname "$SERVER_NAME"
}

configure_root_password() {
  log "Updating root password"
  echo "root:$ROOT_PASSWORD" | chpasswd
}

configure_ufw() {
  log "Configuring UFW"
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
  require_cmd ss
  require_cmd sysctl
  load_env
  require_vars
  validate_port
  DISABLE_IPV6="${DISABLE_IPV6:-true}"
  validate_bool "$DISABLE_IPV6"
  check_ipv6_status

  configure_hostname
  configure_root_password
  create_or_update_user
  setup_ssh_key
  install_packages
  configure_ufw
  configure_ssh
  ensure_fail2ban

  local connect_host="${SERVER_IP_V4:-${SERVER_DOMAIN:-<SERVER_IP>}}"
  log "Done. Test the new SSH login with: ssh $USER_NAME@$connect_host -p $PORT_SSH"
  log "Keep the current root session open until the new SSH session works in a separate terminal"
}

main "$@"
