# Remnawave Node Quick Setup

Simple automation scripts for preparing an Ubuntu server and deploying a **Remnawave Node** with Docker, TLS certificates, and basic firewall configuration.

This repository is intended for users who want to bootstrap a fresh server quickly and verify that the node was configured correctly.

## What this repository contains

```text
remnawave/
|-- .gitignore
|-- README.md
|-- remnawave-panel/
|   |-- .env.example
|   |-- setup-ubuntu.sh
|   |-- setup-remnawave-panel.sh
|   |-- setup-subscription-page.sh
|   `-- check-setup.sh
|-- wiki/
|   |-- remnawave-panel.md
|   `-- remnawave-node.md
`-- remnawave-node/
    |-- .env.example
    |-- setup-ubuntu.sh
    |-- setup-remnawave-node.sh
    `-- check-setup.sh
```

## Included scripts

### `remnawave-node/setup-ubuntu.sh`

Prepares a fresh Ubuntu server:

* sets the hostname
* changes the `root` password
* creates a secondary user
* adds an SSH public key
* updates system packages
* installs `nano`, `fail2ban`, `ufw`, and `less`
* changes the SSH port
* disables SSH login for `root`
* disables password-based SSH authentication
* opens the configured SSH port in UFW
* enables `fail2ban` and UFW

### `remnawave-node/setup-remnawave-node.sh`

Deploys a Remnawave Node:

* installs Docker and Docker Compose plugin if missing
* opens `80/tcp`
* opens `443/tcp`
* opens `PORT_NODE`
* opens `8443/tcp` for `acme.sh`
* opens ports from `PORT_ARRAY_INBOUNDS`
* installs `acme.sh`
* issues a Let's Encrypt certificate for `SERVER_DOMAIN`
* stores certificates in `/etc/ssl/remnawave-node`
* creates `/opt/remnanode/docker-compose.yml`
* starts the `remnanode` container

### `remnawave-node/check-setup.sh`

Verifies the final setup:

* checks required commands and services
* shows `fail2ban`, `docker`, and UFW status
* shows SSH-related configuration
* prints service health information
* prints all UFW rules
* prints all listening ports
* checks certificate files
* checks Docker Compose file presence
* checks whether the `remnanode` container is running

## Requirements

Before you begin, make sure you have:

* a server running **Ubuntu 24.04**
* root access to the server
* a domain name already pointed to the server
* a valid SSH public key
* the ability to open the required ports from the internet

## Environment configuration

Copy the example environment file:

```bash
cp remnawave-node/.env.example remnawave-node/.env
nano remnawave-node/.env
```

Fill in all required values before running any script.

## `.env` variables

The scripts load `remnawave-node/.env` by default.

### Ubuntu setup

```env
ROOT_PASSWORD=
USER_NAME=
USER_PASSWORD=
PORT_SSH=
SSH_PUB=
SERVER_IP_V4=
SERVER_NAME=
SERVER_DOMAIN=
```

### Remnawave Node setup

```env
DOMAIN_MAIL=
PORT_NODE=
NODE_SECRET=
PORT_ARRAY_INBOUNDS=
REMNAWAVE_NODE_IMAGE=remnawave/node:latest
```

### Example

```env
ROOT_PASSWORD=superStrongRootPass
USER_NAME=deploy
USER_PASSWORD=superStrongUserPass
PORT_SSH=10022
SSH_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... me@example"
SERVER_IP_V4=203.0.113.10
SERVER_NAME=remnawave-prod-01
SERVER_DOMAIN=node.example.com

DOMAIN_MAIL=admin@example.com
PORT_NODE=22222
NODE_SECRET=very-secret-key
PORT_ARRAY_INBOUNDS=30000,30001
REMNAWAVE_NODE_IMAGE=remnawave/node:latest
```

## Usage

### 1. Connect to the server

Log in to the server over SSH as `root`:

```bash
ssh root@YOUR_SERVER_IP
```

### 2. Clone the repository on the server

Run the following commands directly on the server:

```bash
apt update && apt install -y git
git clone https://github.com/jenesei-software/remnawave.git
cd remnawave
cp remnawave-node/.env.example remnawave-node/.env
nano remnawave-node/.env
```

Fill in `remnawave-node/.env` before running any scripts.

### 3. Run the Ubuntu bootstrap script

```bash
sudo bash remnawave-node/setup-ubuntu.sh
```

After the script finishes, **do not close your current root session**.
Open a **new terminal tab** and verify that SSH access with the new user works:

```bash
ssh USER_NAME@YOUR_SERVER_IP -p PORT_SSH
```

Only continue after confirming that the new SSH login works.

### 4. Run the Remnawave Node setup

After verifying the new SSH access:

```bash
sudo bash remnawave-node/setup-remnawave-node.sh
```

During this step, the script opens:

* `80/tcp`
* `443/tcp`
* `PORT_NODE/tcp`
* `8443/tcp` for `acme.sh`
* all ports from `PORT_ARRAY_INBOUNDS` over TCP

### 5. Run the verification script

```bash
sudo bash remnawave-node/check-setup.sh
```

## Quick start

```bash
ssh root@YOUR_SERVER_IP
apt update && apt install -y git
git clone https://github.com/jenesei-software/remnawave.git
cd remnawave
cp remnawave-node/.env.example remnawave-node/.env
nano remnawave-node/.env
sudo bash remnawave-node/setup-ubuntu.sh
```

After verifying the new SSH login:

```bash
cd remnawave
sudo bash remnawave-node/setup-remnawave-node.sh
sudo bash remnawave-node/check-setup.sh
```

## Useful commands

### View container logs

```bash
cd /opt/remnanode
docker compose logs -f
```

### Stop the node

```bash
cd /opt/remnanode
docker compose down
```

### Show open firewall rules

```bash
ufw status numbered
```

### Check fail2ban

```bash
systemctl status fail2ban
```

## Important notes

* Run `setup-ubuntu.sh` carefully on a fresh server and only if your SSH public key is correct.
* The script disables password-based SSH login, so an invalid `SSH_PUB` value may lock you out of the server.
* `sudo` is normally not required after `setup-ubuntu.sh`; SSH must switch to `PORT_SSH` immediately.
* If the new SSH port does not accept connections right away on Ubuntu 24.04, run: `sudo systemctl daemon-reload && sudo systemctl restart ssh.socket && sudo systemctl restart ssh`.
* Keep your current root SSH session open until a new session on `PORT_SSH` is confirmed.
* `acme.sh` requires your domain to already point to the target server.
* The required validation port must be reachable from the public internet.
* This project opens `8443/tcp` as part of the certificate automation flow.
* Ports from `PORT_ARRAY_INBOUNDS` are opened as **TCP** ports only.
* If you also need UDP ports, extend the firewall rules accordingly.
* These scripts are intended for **Ubuntu 24.04**.
