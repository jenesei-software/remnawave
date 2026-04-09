# Remnawave quick setup

Набор скриптов для быстрого подъема сервера под Remnawave Node.

Основа собрана по твоим двум инструкциям: настройка Ubuntu и настройка Remnawave Node. Исходные заметки были про UFW, SSH, fail2ban, сертификаты через `acme.sh`, docker compose и запуск `remnawave/node:latest`. fileciteturn0file1 fileciteturn0file0

## Структура

```text
remnawave-quick-setup/
├── .env.example
├── .gitignore
├── README.md
└── remnawave-node/
    ├── setup-ubuntu.sh
    ├── setup-remnawave-node.sh
    └── check-setup.sh
```

## Что делает каждый скрипт

### `remnawave-node/setup-ubuntu.sh`

Базовая подготовка Ubuntu:
- меняет hostname
- задает пароль root
- создает второго пользователя
- добавляет SSH public key
- обновляет систему
- ставит `nano`, `fail2ban`, `ufw`, `less`
- меняет SSH порт
- отключает root login по SSH
- отключает вход по паролю
- открывает новый SSH порт в UFW
- включает `fail2ban` и `ufw`

### `remnawave-node/setup-remnawave-node.sh`

Поднимает ноду Remnawave:
- ставит Docker и Compose plugin, если их нет
- открывает `PORT_NODE`, `8443/tcp` для `acme.sh` и inbound-порты в UFW
- ставит `acme.sh`
- выпускает сертификат Let's Encrypt для `SERVER_DOMAIN`
- кладет сертификаты в `/etc/ssl/remnawave-node`
- создает `/opt/remnanode/docker-compose.yml`
- запускает контейнер `remnanode`

### `remnawave-node/check-setup.sh`

Проверяет результат:
- наличие команд и сервисов
- статус `fail2ban`, `docker`, `ufw`
- SSH настройки
- явный статус сервисов
- все открытые правила UFW
- все слушающие порты на сервере
- наличие сертификатов
- наличие compose-файла
- запущен ли контейнер `remnanode`

## Подготовка

Скопируй пример env:

```bash
cp .env.example .env
nano .env
```

Заполни `.env`.

## Переменные `.env`

### Базовая настройка Ubuntu

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

### Настройка Remnawave Node

```env
DOMAIN_MAIL=
PORT_NODE=
NODE_SECRET=
PORT_ARRAY_INBOUNDS=
REMNAWAVE_NODE_IMAGE=remnawave/node:latest
```

Пример:

```env
ROOT_PASSWORD=superStrongRootPass
USER_NAME=deploy
USER_PASSWORD=superStrongUserPass
PORT_SSH=10022
SSH_PUB=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... me@example
SERVER_IP_V4=203.0.113.10
SERVER_NAME=remnawave-prod-01
SERVER_DOMAIN=node.example.com
DOMAIN_MAIL=admin@example.com
PORT_NODE=22222
NODE_SECRET=very-secret-key
PORT_ARRAY_INBOUNDS=80,443,30000,30001
REMNAWAVE_NODE_IMAGE=remnawave/node:latest
```

## Как использовать

### 1. Залить проект на сервер

Локально:

```bash
git clone <your-repo>
cd remnawave-quick-setup
cp .env.example .env
nano .env
```

Потом передай проект на сервер любым удобным способом.

### 2. Подключиться к серверу под root

```bash
ssh root@YOUR_SERVER_IP
```

### 3. Запустить базовую настройку Ubuntu

```bash
cd /path/to/remnawave-quick-setup
sudo bash remnawave-node/setup-ubuntu.sh
```

Сразу после выполнения проверь вход в **новой сессии**:

```bash
ssh USER_NAME@YOUR_SERVER_IP -p PORT_SSH
```

### 4. Поднять Remnawave Node

Уже после входа новым пользователем или через `sudo`:

```bash
cd /path/to/remnawave-quick-setup
sudo bash remnawave-node/setup-remnawave-node.sh
```

Во время этого шага скрипт автоматически откроет:
- `PORT_NODE/tcp`
- `8443/tcp` для `acme.sh`
- все порты из `PORT_ARRAY_INBOUNDS` по TCP

### 5. Прогнать проверку

```bash
cd /path/to/remnawave-quick-setup
sudo bash remnawave-node/check-setup.sh
```

## Права на запуск

Если нужно:

```bash
chmod +x remnawave-node/*.sh
```

## Полезные команды

Логи контейнера:

```bash
cd /opt/remnanode
docker compose logs -f
```

Остановить ноду:

```bash
cd /opt/remnanode
docker compose down
```

Посмотреть открытые порты в UFW:

```bash
sudo ufw status numbered
```

Проверить fail2ban:

```bash
sudo systemctl status fail2ban
```

## Важные замечания

- `setup-ubuntu.sh` лучше запускать поэтапно и только если у тебя уже есть рабочий SSH key.
- Скрипт отключает SSH-вход по паролю, поэтому без корректного `SSH_PUB` можно потерять доступ.
- Для шага с `acme.sh` в этом проекте дополнительно открывается `8443/tcp` через UFW, потому что ты этого хочешь в автоматизации и документации.
- Выпуск сертификата через `acme.sh` требует, чтобы домен уже смотрел на сервер и нужный порт для проверки был доступен снаружи.
- В `PORT_ARRAY_INBOUNDS` сейчас открываются TCP-порты. Если тебе нужны еще и UDP, это можно легко добавить отдельным правилом.
- Скрипты рассчитаны на Ubuntu 24.04, потому что именно эта версия была в твоей инструкции. fileciteturn0file1

## Что можно улучшить дальше

- добавить `--dry-run`
- добавить rollback для SSH-конфига
- добавить systemd health-check
- добавить отдельный deploy-скрипт
- добавить поддержку UDP inbound-портов
