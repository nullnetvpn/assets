#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ok "The script is initialized and starts working..."

################################################################################
# Variables
################################################################################

BASE_DIR="/opt/remnanode"

SSL_DIR="$BASE_DIR/ssl"
NGINX_DIR="$BASE_DIR/nginx"

COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
NGINX_CONFIG="$NGINX_DIR/nginx.conf"

CF_CONFIG="/root/.remnanode_cf.conf"

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
# Root
################################################################################

[[ "$EUID" == "0" ]] || fail "Run script as root."


################################################################################
# Dependencies
################################################################################

info "Installing dependencies..."

apt update

apt install -y \
    curl \
    wget \
    socat \
    ca-certificates \
    ufw \
    cron


################################################################################
# Docker
################################################################################

if ! command -v docker >/dev/null 2>&1; then

    info "Installing Docker..."

    curl -fsSL https://get.docker.com | sh

fi


systemctl enable docker
systemctl start docker


command -v docker >/dev/null 2>&1 || fail "Docker installation failed."

ok "Docker ready."


################################################################################
# Directories
################################################################################

mkdir -p \
    "$BASE_DIR" \
    "$SSL_DIR" \
    "$NGINX_DIR" \
    /var/log/remnanode


################################################################################
# acme.sh
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

fi


################################################################################
# Cloudflare token
################################################################################

if [[ -f "$CF_CONFIG" ]]; then

    source "$CF_CONFIG"

else

    ask_secret CF_Token "Enter Cloudflare API Token: "

    [[ -n "$CF_Token" ]] || fail "Cloudflare token empty."


    cat > "$CF_CONFIG" <<EOF
export CF_Token="$CF_Token"
EOF

    chmod 600 "$CF_CONFIG"

fi


source "$CF_CONFIG"

export CF_Token


################################################################################
# SSL
################################################################################

info "Checking SSL certificates..."


if [[ -f "$SSL_DIR/fullchain.pem" && -f "$SSL_DIR/privkey.pem" ]]; then

    ok "Certificates already exist in $SSL_DIR"


else

    info "Certificates not found in $SSL_DIR"


    ACME_CERT="/root/.acme.sh/${DOMAIN}_ecc"


    if [[ -d "$ACME_CERT" ]]; then

        info "Found existing acme.sh certificate."

    else

        info "Certificate not found. Issuing new certificate..."

        acme.sh \
            --issue \
            --force \
            -d "$DOMAIN" \
            --dns dns_cf

    fi


    info "Installing certificate..."


    acme.sh \
        --install-cert \
        -d "$DOMAIN" \
        --key-file "$SSL_DIR/privkey.pem" \
        --fullchain-file "$SSL_DIR/fullchain.pem" \
        --reloadcmd "
cd $BASE_DIR &&
docker compose restart nginx || true
"

fi


ok "SSL ready."


################################################################################
# Nginx config
################################################################################

info "Creating nginx config..."


cat > "$NGINX_CONFIG" <<EOF
server {

    listen 127.0.0.1:$NGINX_PORT ssl;

    server_name $DOMAIN;


    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;


    ssl_protocols TLSv1.2 TLSv1.3;


    location / {
        return 403;
    }

}
EOF


################################################################################
# RemnaNode settings
################################################################################

if [[ -f "$COMPOSE_FILE" ]]; then

    ok "Existing docker-compose.yml detected."

else

    ask_secret SECRET_KEY "Enter panel Secret Key: "

    [[ -n "$SECRET_KEY" ]] || fail "Secret Key empty."


    ask ALLOW_IP "Enter IP allowed for port 2222: "


    ################################################################################
    # Firewall
    ################################################################################

    info "Configuring UFW..."

    ufw --force enable

    ufw allow from "$ALLOW_IP" to any port "$NODE_PORT" proto tcp


    ok "Firewall configured."


    ################################################################################
    # Docker compose
    ################################################################################

    info "Creating docker-compose.yml..."


    cat > "$COMPOSE_FILE" <<EOF
services:

    nginx:
        image: nginx:latest
        container_name: remnanode-nginx
        restart: always
        network_mode: host
        volumes:
            - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
            - ./ssl:/etc/nginx/ssl:ro


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
            - ./ssl:/opt/remnanode/ssl:ro


        logging:
            driver: json-file
            options:
                max-size: 100m
                max-file: 5
EOF


    ok "docker-compose.yml created."

fi


################################################################################
# Start containers
################################################################################

info "Starting Remnanode stack..."


cd "$BASE_DIR"


docker compose up -d --remove-orphans


################################################################################
# Finish
################################################################################

echo
ok "Installation completed!"
echo

echo "Domain:"
echo "https://$DOMAIN"

echo
echo "TLS backend:"
echo "127.0.0.1:$NGINX_PORT"

echo
echo "Node port:"
echo "$NODE_PORT"

echo
echo "Directory:"
echo "$BASE_DIR"
