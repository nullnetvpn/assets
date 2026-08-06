#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

################################################################################
# Config
################################################################################

SSL_DIR="/opt/remnanode/ssl"
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
SERVICE_NAME="remnanode"

CF_CONFIG="/root/.remnanode_ssl.conf"

NGINX_CONFIG="/etc/nginx/conf.d/remnanode-local.conf"
NGINX_PORT="8000"

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

[[ $EUID -eq 0 ]] || fail "Run as root."

################################################################################
# Install packages
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
    cron

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
# Cloudflare API Token
################################################################################

if [[ -f "$CF_CONFIG" ]]; then

    source "$CF_CONFIG"

else

    ask_secret CF_Token "Enter Cloudflare API Token: "

    [[ -n "$CF_Token" ]] || fail "Token is empty."

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

mkdir -p "$SSL_DIR"

info "Issuing certificate..."

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
docker compose -f $COMPOSE_FILE restart $SERVICE_NAME || true
"

ok "Certificate installed."

################################################################################
# Local HTTPS nginx :8000
################################################################################

info "Creating local HTTPS server..."

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

ok "HTTPS backend started: 127.0.0.1:$NGINX_PORT"

################################################################################
# Docker compose volume
################################################################################

if [[ -f "$COMPOSE_FILE" ]]; then

    if ! grep -q "/opt/remnanode/ssl:/opt/remnanode/ssl:ro" "$COMPOSE_FILE"; then

        info "Updating docker-compose.yml..."

        cp "$COMPOSE_FILE" "$COMPOSE_FILE.backup"

        python3 <<PY
from pathlib import Path

path = Path("$COMPOSE_FILE")
data = path.read_text()

volume = "      - /opt/remnanode/ssl:/opt/remnanode/ssl:ro"

if volume not in data:

    if "    volumes:" in data:
        data = data.replace(
            "    volumes:",
            "    volumes:\n" + volume,
            1
        )
    else:
        data += "\n    volumes:\n" + volume + "\n"

path.write_text(data)
PY

        ok "docker-compose.yml updated."

    fi

else

    echo "Warning: docker-compose.yml not found."

fi

################################################################################
# Restart RemnaNode
################################################################################

if [[ -f "$COMPOSE_FILE" ]]; then

    info "Starting RemnaNode..."

    docker compose \
        -f "$COMPOSE_FILE" \
        up -d

fi

################################################################################
# Result
################################################################################

echo
ok "Installation completed."
echo
echo "Domain:"
echo "  https://$DOMAIN"
echo
echo "Certificate:"
echo "  $SSL_DIR/fullchain.pem"
echo "  $SSL_DIR/privkey.pem"
echo
echo "Local TLS backend:"
echo "  127.0.0.1:$NGINX_PORT"
echo
