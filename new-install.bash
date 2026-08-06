#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

################################################################################
# Variables
################################################################################

BASE_DIR="/opt/remnanode"
SSL_DIR="$BASE_DIR/ssl"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

CF_CONFIG="/root/.remnanode_cf.conf"

NGINX_CONFIG="/etc/nginx/conf.d/remnanode.conf"
NGINX_PORT="8000"

NODE_PORT="2222"

################################################################################
# Functions
################################################################################

info() {
    echo -e "\033[36m[*]\033[0m $1"
}

ok() {
    echo -e "\033[32m[✓]\033[0m $1"
}

fail() {
    echo -e "\033[31m[✗]\033[0m $1"
    exit 1
}

ask() {
    local var="$1"
    local text="$2"

    read -rp "$text" "$var" </dev/tty
}

ask_secret() {
    local var="$1"
    local text="$2"

    read -rsp "$text" "$var" </dev/tty
    echo
}

################################################################################
# Root check
################################################################################

[[ "$EUID" == "0" ]] || fail "Run script as root."

################################################################################
# Packages
################################################################################

info "Installing dependencies..."

apt update

apt install -y \
    curl \
    wget \
    socat \
    ca-certificates \
    nginx \
    python3 \
    ufw \
    cron \
    docker.io \
    docker-compose-plugin

systemctl enable docker
systemctl start docker


################################################################################
# Directory
################################################################################

mkdir -p "$SSL_DIR"
mkdir -p "$BASE_DIR"
mkdir -p /var/log/remnanode


################################################################################
# Install acme.sh
################################################################################

export PATH="/root/.acme.sh:$PATH"

if ! command -v acme.sh >/dev/null 2>&1; then

    info "Installing acme.sh..."

    curl -fsSL https://get.acme.sh | sh

    export PATH="/root/.acme.sh:$PATH"

fi


################################################################################
# Domain
################################################################################

ask DOMAIN "Enter domain: "

[[ -n "$DOMAIN" ]] || fail "Domain is empty."


################################################################################
# ACME account
################################################################################

if ! acme.sh --list >/dev/null 2>&1; then

    info "Registering ACME account..."

    acme.sh \
        --register-account \
        -m "noreply-$(date +%s)@example.com"

    ok "ACME account registered."

fi


################################################################################
# Cloudflare token
################################################################################

if [[ -f "$CF_CONFIG" ]]; then

    source "$CF_CONFIG"

else

    ask_secret CF_Token "Enter Cloudflare API Token: "

    [[ -n "$CF_Token" ]] || fail "Cloudflare Token empty."

    cat > "$CF_CONFIG" <<EOF
export CF_Token="$CF_Token"
EOF

    chmod 600 "$CF_CONFIG"

fi


source "$CF_CONFIG"

export CF_Token


################################################################################
# Certificate
################################################################################

info "Requesting certificate for $DOMAIN..."

acme.sh \
    --issue \
    -d "$DOMAIN" \
    --dns dns_cf


info "Installing certificate..."

acme.sh \
    --install-cert \
    -d "$DOMAIN" \
    --key-file "$SSL_DIR/privkey.pem" \
    --fullchain-file "$SSL_DIR/fullchain.pem" \
    --reloadcmd "
systemctl reload nginx
"


ok "Certificate installed."


################################################################################
# Nginx HTTPS local backend
################################################################################

info "Creating nginx TLS backend..."

cat > "$NGINX_CONFIG" <<EOF
server {

    listen 127.0.0.1:$NGINX_PORT ssl;

    server_name $DOMAIN;

    ssl_certificate     $SSL_DIR/fullchain.pem;
    ssl_certificate_key $SSL_DIR/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        return 403;
    }

}
EOF


nginx -t

systemctl enable nginx
systemctl restart nginx

ok "Local HTTPS started on 127.0.0.1:$NGINX_PORT"


################################################################################
# RemnaNode settings
################################################################################

ask SECRET_KEY "Enter panel Secret Key: "

[[ -n "$SECRET_KEY" ]] || fail "Secret key empty."


ask ALLOW_IP "Enter IP allowed for port 2222: "


################################################################################
# UFW
################################################################################

info "Configuring firewall..."

ufw --force enable

ufw allow from "$ALLOW_IP" to any port "$NODE_PORT" proto tcp


ok "Port $NODE_PORT opened for $ALLOW_IP"


################################################################################
# Docker compose
################################################################################

info "Creating docker-compose.yml"


cat > "$COMPOSE_FILE" <<EOF
services:
    remnanode:
        container_name: remnanode
        hostname: remnanode
        image: remnawave/node:latest
        network_mode: host
        restart: always
        cap_add:
            - NET_ADMIN
        ulimits:
            nofile:
                soft: 1048576
                hard: 1048576
        environment:
            - NODE_PORT=$NODE_PORT
            - SECRET_KEY=$SECRET_KEY
        volumes:
            - /dev/shm:/dev/shm
            - /var/log/remnanode:/var/log/remnanode
            - /opt/remnanode/ssl:/opt/remnanode/ssl:ro
        logging:
            driver: json-file
            options:
                max-size: 100m
                max-file: 5
EOF


ok "docker-compose.yml created"


################################################################################
# Start RemnaNode
################################################################################

info "Starting RemnaNode..."

cd "$BASE_DIR"

docker compose up -d


################################################################################
# Finish
################################################################################

echo
ok "Installation completed!"
echo

echo "Domain:"
echo "https://$DOMAIN"

echo
echo "SSL:"
echo "$SSL_DIR/fullchain.pem"
echo "$SSL_DIR/privkey.pem"

echo
echo "Local HTTPS:"
echo "127.0.0.1:$NGINX_PORT"

echo
echo "RemnaNode port:"
echo "$NODE_PORT"

echo
echo "Allowed IP:"
echo "$ALLOW_IP"
