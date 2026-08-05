#!/usr/bin/env bash

set -euo pipefail

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

WORKDIR="/opt/null-tls"

info() {
    echo -e "${BLUE}[*]${RESET} $1"
}

success() {
    echo -e "${GREEN}[+]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[!]${RESET} $1"
}

error() {
    echo -e "${RED}[-]${RESET} $1"
}

if [[ $EUID -ne 0 ]]; then
    error "Запустите скрипт от root."
    exit 1
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

success "Рабочая директория: $WORKDIR"

info "Проверка Docker..."

if ! command -v docker >/dev/null 2>&1; then

    warn "Docker не найден. Устанавливаю..."

    apt update
    apt install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(lsb_release -cs) stable" \
> /etc/apt/sources.list.d/docker.list

    apt update

    apt install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    success "Docker установлен."

else
    success "Docker уже установлен."
fi

echo
read -rp "Введите домен: " DOMAIN

if [[ -z "$DOMAIN" ]]; then
    error "Домен не указан."
    exit 1
fi

cat > .env <<EOF
DOMAIN=$DOMAIN
EOF

success ".env создан."

cat > docker-compose.yml <<'EOF'
services:
  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped

    ports:
      - "80:80"
      - "443:443"

    env_file:
      - .env

    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
EOF

success "docker-compose.yml создан."

cat > Caddyfile <<'EOF'
{$DOMAIN} {
    reverse_proxy https://127.0.0.1:7443 {
        transport http {
            tls
            tls_insecure_skip_verify
        }
    }
}
EOF

success "Caddyfile создан."

info "Проверка Xray..."

if command -v ss >/dev/null 2>&1; then
    if ss -ltn | grep -q "127.0.0.1:7443"; then
        success "Xray слушает 127.0.0.1:7443"
    else
        warn "Xray не найден на 127.0.0.1:7443"
        warn "Caddy всё равно будет запущен."
    fi
fi

info "Запуск Caddy..."

docker compose up -d

echo
success "Установка завершена!"

echo
echo "=================================="
echo "Рабочая директория : $WORKDIR"
echo "Домен              : https://$DOMAIN"
echo "Xray               : 127.0.0.1:7443"
echo "=================================="

echo
echo "Полезные команды:"
echo "cd $WORKDIR"
echo "docker compose logs -f"
echo "docker compose restart"
echo "docker compose down"