# Remnawave Panel Quick Setup

This repository includes a dedicated `remnawave-panel/` folder for installing **Remnawave Panel** on a fresh server with Docker, **Nginx** as the reverse proxy, and a bundled **subscription-page** container on the same host.

The workflow in this guide follows the current official Remnawave documentation for:

* panel installation
* environment variables
* Nginx reverse proxy
* bundled subscription-page installation
* bundled subscription-page Nginx integration

This guide treats the bundled **subscription-page** as part of the complete setup, because public subscription links are expected to resolve through it.

## What this repository contains

```text
remnawave/
|-- .gitignore
|-- README.md
|-- remnawave-node/
|   |-- .env.example
|   |-- setup-ubuntu.sh
|   |-- setup-remnawave-node.sh
|   `-- check-setup.sh
|-- remnawave-panel/
|   |-- .env.example
|   |-- setup-ubuntu.sh
|   |-- setup-remnawave-panel.sh
|   |-- setup-subscription-page.sh
|   `-- check-setup.sh
`-- wiki/
    |-- remnawave-node.md
    `-- remnawave-panel.md
```

## Included scripts

### `remnawave-panel/setup-ubuntu.sh`

Prepares a fresh Ubuntu server:

* sets the hostname
* changes the `root` password
* creates a secondary user
* adds an SSH public key
* updates system packages
* installs `nano`, `fail2ban`, `ufw`, `less`, `curl`, and `openssl`
* changes the SSH port
* disables SSH login for `root`
* disables password-based SSH authentication
* opens the configured SSH port in UFW
* enables `fail2ban` and UFW

### `remnawave-panel/setup-remnawave-panel.sh`

Deploys the base Remnawave Panel stack:

* installs required base packages
* installs Docker with Docker Compose if missing
* installs `cron` and `socat` for `acme.sh`
* opens `443/tcp` and `8443/tcp`
* downloads the official Remnawave Panel `docker-compose-prod.yml`
* downloads the official `.env.sample`
* installs `acme.sh`
* issues the TLS certificate for `PANEL_DOMAIN`
* generates strong secrets for JWT, metrics, webhook signing, and Postgres
* applies panel runtime settings from `remnawave-panel/.env`
* creates `/opt/remnawave/nginx/nginx.conf`
* creates `/opt/remnawave/nginx/docker-compose.yml`
* starts Remnawave Panel containers
* starts the Nginx reverse proxy for the panel domain

### `remnawave-panel/setup-subscription-page.sh`

Deploys the bundled subscription page and extends the Nginx setup:

* updates `SUB_PUBLIC_DOMAIN` in `/opt/remnawave/.env`
* creates `/opt/remnawave/subscription/docker-compose.yml`
* creates `/opt/remnawave/subscription/.env`
* issues the TLS certificate for `SUBSCRIPTION_PAGE_DOMAIN`
* rewrites `/opt/remnawave/nginx/nginx.conf` with:
  the `remnawave-subscription-page` upstream
  a second `server` block for `SUBSCRIPTION_PAGE_DOMAIN`
* rewrites `/opt/remnawave/nginx/docker-compose.yml` to mount the second certificate pair
* recreates the `remnawave` container so the new `SUB_PUBLIC_DOMAIN` is applied
* starts the `remnawave-subscription-page` container
* recreates the Nginx container with both virtual hosts

### `remnawave-panel/check-setup.sh`

Verifies the final setup:

* checks required commands
* checks Docker service state
* checks deployment files
* checks `remnawave`, `remnawave-db`, `remnawave-redis`, and `remnawave-nginx`
* checks `remnawave-subscription-page` when bundled subscription is configured
* checks the `remnawave-network` Docker network
* verifies that Remnawave stays bound to `127.0.0.1`
* verifies that the bundled subscription page stays bound to `127.0.0.1:3010`
* verifies the local panel health endpoint
* verifies the HTTPS virtual host for `PANEL_DOMAIN`
* verifies the HTTPS virtual host for `SUBSCRIPTION_PAGE_DOMAIN` when configured
* checks that both certificate pairs exist when bundled subscription is configured
* prints UFW status and listening ports

## Requirements

The official Remnawave docs currently recommend:

* Ubuntu or Debian
* minimum `2 GB` RAM, recommended `4 GB`
* minimum `2` CPU cores, recommended `4`
* `20 GB` disk
* Docker with Docker Compose

For this repository, the scripts are written for a fresh **Ubuntu 24.04** server.

Before you begin, make sure you have:

* root access to the server
* a domain name for the panel already pointed to the server
* a domain or subdomain for the bundled subscription page already pointed to the server
* a valid SSH public key
* the ability to open `443/tcp`, `8443/tcp`, and your SSH port from the internet

## Environment configuration

Copy the example environment file:

```bash
cp remnawave-panel/.env.example remnawave-panel/.env
nano remnawave-panel/.env
```

The scripts load `remnawave-panel/.env` by default.

The bundled `.env.example` is split into:

* required values for `setup-ubuntu.sh`
* required values for `setup-remnawave-panel.sh`
* required values for `setup-subscription-page.sh`
* optional and advanced values you can leave as-is at first

## `.env` variables

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

### Remnawave Panel setup

```env
PANEL_DOMAIN=
DOMAIN_MAIL=
SUB_PUBLIC_DOMAIN=
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
IS_DOCS_ENABLED=false
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
METRICS_USER=admin
POSTGRES_USER=postgres
POSTGRES_DB=postgres
```

### Bundled subscription-page setup

```env
SUBSCRIPTION_PAGE_DOMAIN=
REMNAWAVE_API_TOKEN=
CUSTOM_SUB_PREFIX=
MARZBAN_LEGACY_LINK_ENABLED=false
MARZBAN_LEGACY_SECRET_KEY=
CADDY_AUTH_API_TOKEN=
```

### Variable notes

* `PANEL_DOMAIN` is required. This is the public HTTPS domain for the panel.
* `DOMAIN_MAIL` is required for `acme.sh` certificate issuance.
* `SUBSCRIPTION_PAGE_DOMAIN` is the public HTTPS domain for the bundled subscription page.
* `REMNAWAVE_API_TOKEN` is created in the Remnawave dashboard after the first admin login.
* In `remnawave-panel/.env.example`, all fields marked `REQUIRED` are the ones you must fill in.
* `SUB_PUBLIC_DOMAIN` can be left empty. If `SUBSCRIPTION_PAGE_DOMAIN` is set, `setup-subscription-page.sh` will use it automatically.
* If `CUSTOM_SUB_PREFIX` is set, `setup-subscription-page.sh` appends it to `SUB_PUBLIC_DOMAIN`.
* The deployed panel runtime file lives at `/opt/remnawave/.env`.
* The bundled subscription page runtime file lives at `/opt/remnawave/subscription/.env`.
* Panel TLS files are stored at:
  `/opt/remnawave/nginx/fullchain.pem`
  `/opt/remnawave/nginx/privkey.key`
* Subscription page TLS files are stored at:
  `/opt/remnawave/nginx/subdomain_fullchain.pem`
  `/opt/remnawave/nginx/subdomain_privkey.key`

### Example

```env
ROOT_PASSWORD=superStrongRootPass
USER_NAME=deploy
USER_PASSWORD=superStrongUserPass
PORT_SSH=10022
SSH_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... me@example"
SERVER_IP_V4=203.0.113.10
SERVER_NAME=remnawave-panel-01
SERVER_DOMAIN=panel.example.com

PANEL_DOMAIN=panel.example.com
DOMAIN_MAIL=admin@example.com
SUB_PUBLIC_DOMAIN=
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1
IS_DOCS_ENABLED=false
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
METRICS_USER=admin
POSTGRES_USER=postgres
POSTGRES_DB=postgres

SUBSCRIPTION_PAGE_DOMAIN=sub.panel.example.com
REMNAWAVE_API_TOKEN=
CUSTOM_SUB_PREFIX=
MARZBAN_LEGACY_LINK_ENABLED=false
MARZBAN_LEGACY_SECRET_KEY=
CADDY_AUTH_API_TOKEN=
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
cp remnawave-panel/.env.example remnawave-panel/.env
nano remnawave-panel/.env
```

### 3. Run the Ubuntu bootstrap script

```bash
sudo bash remnawave-panel/setup-ubuntu.sh
```

After the script finishes, **do not close your current root session**.
Open a **new terminal tab** and verify that SSH access with the new user works:

```bash
ssh USER_NAME@YOUR_SERVER_IP -p PORT_SSH
```

Only continue after confirming that the new SSH login works.

### 4. Run the base panel setup

After verifying the new SSH access:

```bash
sudo bash remnawave-panel/setup-remnawave-panel.sh
```

This script:

* installs the official Remnawave Panel stack
* publishes the panel through Nginx on `PANEL_DOMAIN`
* prepares the server for the second subscription-page step

### 5. Open the panel and create the first admin

Open:

```text
https://YOUR_PANEL_DOMAIN
```

On a new installation, the first user you create in the panel becomes the **super-admin**.

### 6. Create an API token for the subscription page

In the Remnawave dashboard, open:

```text
Settings -> API Tokens
```

Create a token and put it into `remnawave-panel/.env`:

```env
REMNAWAVE_API_TOKEN=YOUR_TOKEN_HERE
```

### 7. Run the bundled subscription-page setup

After the API token is added:

```bash
sudo bash remnawave-panel/setup-subscription-page.sh
```

This script:

* creates `/opt/remnawave/subscription`
* creates the bundled `remnawave-subscription-page` compose and env files
* updates `/opt/remnawave/.env` with the correct `SUB_PUBLIC_DOMAIN`
* issues a second certificate for `SUBSCRIPTION_PAGE_DOMAIN`
* expands Nginx so it serves both:
  `PANEL_DOMAIN`
  `SUBSCRIPTION_PAGE_DOMAIN`

### 8. Run the verification script

```bash
sudo bash remnawave-panel/check-setup.sh
```

### 9. Open the bundled subscription page

After setup, subscription links should resolve through:

```text
https://SUBSCRIPTION_PAGE_DOMAIN/<shortUuid>
```

## Quick start

### Phase 1: panel

```bash
ssh root@YOUR_SERVER_IP
apt update && apt install -y git
git clone https://github.com/jenesei-software/remnawave.git
cd remnawave
cp remnawave-panel/.env.example remnawave-panel/.env
nano remnawave-panel/.env
sudo bash remnawave-panel/setup-ubuntu.sh
```

After verifying the new SSH login:

```bash
cd remnawave
sudo bash remnawave-panel/setup-remnawave-panel.sh
```

### Phase 2: bundled subscription page

After creating the first admin and generating `REMNAWAVE_API_TOKEN`:

```bash
cd remnawave
nano remnawave-panel/.env
sudo bash remnawave-panel/setup-subscription-page.sh
sudo bash remnawave-panel/check-setup.sh
```

## Quick links

### Repository files

* [remnawave-panel/.env.example](../remnawave-panel/.env.example)
* [remnawave-panel/setup-ubuntu.sh](../remnawave-panel/setup-ubuntu.sh)
* [remnawave-panel/setup-remnawave-panel.sh](../remnawave-panel/setup-remnawave-panel.sh)
* [remnawave-panel/setup-subscription-page.sh](../remnawave-panel/setup-subscription-page.sh)
* [remnawave-panel/check-setup.sh](../remnawave-panel/check-setup.sh)

### Important files on the server

* `/opt/remnawave/.env` - runtime environment for the panel stack
* `/opt/remnawave/docker-compose.yml` - main Remnawave Panel compose file
* `/opt/remnawave/nginx/nginx.conf` - Nginx virtual hosts for panel and subscription page
* `/opt/remnawave/nginx/docker-compose.yml` - Nginx container definition
* `/opt/remnawave/nginx/fullchain.pem` - TLS certificate for `PANEL_DOMAIN`
* `/opt/remnawave/nginx/privkey.key` - TLS private key for `PANEL_DOMAIN`
* `/opt/remnawave/nginx/subdomain_fullchain.pem` - TLS certificate for `SUBSCRIPTION_PAGE_DOMAIN`
* `/opt/remnawave/nginx/subdomain_privkey.key` - TLS private key for `SUBSCRIPTION_PAGE_DOMAIN`
* `/opt/remnawave/subscription/.env` - bundled subscription-page runtime environment
* `/opt/remnawave/subscription/docker-compose.yml` - bundled subscription-page compose file

## Useful commands

### Recreate the full panel stack

```bash
cd /opt/remnawave
docker compose down
docker compose up -d
```

### Show panel logs

```bash
cd /opt/remnawave
docker compose logs -f -t
```

### Open the panel runtime environment

```bash
nano /opt/remnawave/.env
```

### Show bundled subscription-page logs

```bash
cd /opt/remnawave/subscription
docker compose logs -f -t
```

### Recreate the bundled subscription-page

```bash
cd /opt/remnawave/subscription
docker compose down
docker compose up -d
```

### Open the bundled subscription-page environment

```bash
nano /opt/remnawave/subscription/.env
```

### Show Nginx logs

```bash
cd /opt/remnawave/nginx
docker compose logs -f -t
```

### Recreate Nginx

```bash
cd /opt/remnawave/nginx
docker compose down
docker compose up -d
```

### Open the active Nginx config

```bash
nano /opt/remnawave/nginx/nginx.conf
```

### Recreate only the Remnawave container after editing `/opt/remnawave/.env`

```bash
cd /opt/remnawave
docker compose up -d --force-recreate remnawave
```

### Restart the bundled subscription page

```bash
cd /opt/remnawave/subscription
docker compose down && docker compose up -d
```

### Open the Rescue CLI

```bash
docker exec -it remnawave cli
```

### Show open firewall rules

```bash
ufw status numbered
```

## Important notes

* According to the official docs, a reverse proxy is required for Remnawave Panel. This repository uses **Nginx** for that step.
* According to the official docs, Remnawave services should not be exposed directly to the public internet. The official compose file binds the panel and metrics endpoints to `127.0.0.1`.
* According to the official bundled subscription-page guide, the subscription page must be served from the root of its own domain or subdomain. It must not be mounted under a reverse-proxy sub-path like `/subscription`.
* The current official Nginx flow uses `acme.sh` with `--alpn --tlsport 8443`, so `8443/tcp` must stay open for certificate issuance and renewal.
* If you change `/opt/remnawave/.env`, recreate the `remnawave` container. A plain restart is not enough to guarantee env changes are applied.
* If you change `/opt/remnawave/subscription/.env`, recreate the `remnawave-subscription-page` container.
* `IS_DOCS_ENABLED=true` enables the built-in API documentation pages.
* The official Nginx guide warns that ZeroSSL does not support `.ru`, `.su`, and `.рф` zones for this issuance flow.
* For production hardening, review the official Panel Security guides after the base deployment is working.

## Official references

These scripts and instructions were aligned with the official Remnawave documentation and upstream files available on April 16, 2026:

* [Introduction](https://docs.rw/docs/overview/introduction/)
* [Quick start](https://docs.rw/docs/overview/quick-start/)
* [Requirements](https://docs.rw/docs/install/requirements/)
* [Remnawave Panel installation](https://docs.rw/docs/install/remnawave-panel/)
* [Environment Variables](https://docs.rw/docs/install/environment-variables/)
* [Nginx reverse proxy](https://docs.rw/docs/install/reverse-proxies/nginx/)
* [Bundled subscription-page](https://docs.rw/docs/install/subscription-page/bundled/)
* [Bundled subscription-page Nginx section](https://docs.rw/docs/install/subscription-page/bundled#nginx)
* [Panel Security](https://docs.rw/docs/install/panel-security/)
* [Official `docker-compose-prod.yml`](https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml)
* [Official `.env.sample`](https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample)
