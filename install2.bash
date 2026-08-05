#!/usr/bin/env bash

set -euo pipefail

WORKDIR="/opt/null-tls"

GREEN="\e[32m"
RED="\e[31m"
BLUE="\e[34m"
RESET="\e[0m"

info() {
    echo -e "${BLUE}[*]${RESET} $1"
}

ok() {
    echo -e "${GREEN}[+]${RESET} $1"
}

err() {
    echo -e "${RED}[-]${RESET} $1"
}


if [[ $EUID -ne 0 ]]; then
    err "Запустите от root"
    exit 1
fi


mkdir -p "$WORKDIR"
cd "$WORKDIR"

ok "Рабочая директория: $WORKDIR"



# Docker

if ! command -v docker >/dev/null 2>&1; then

    info "Устанавливаем Docker"

    apt update

    apt install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release


    install -m 0755 -d /etc/apt/keyrings


    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor \
        -o /etc/apt/keyrings/docker.gpg


    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian \
$(lsb_release -cs) stable" \
> /etc/apt/sources.list.d/docker.list


    apt update


    apt install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-compose-plugin


    systemctl enable docker
    systemctl start docker

else

    ok "Docker найден"

fi



read -rp "Домен: " DOMAIN </dev/tty


if [[ -z "$DOMAIN" ]]; then
    err "Домен пустой"
    exit 1
fi



cat > .env <<EOF
DOMAIN=$DOMAIN
EOF



mkdir -p acme



cat > docker-compose.yml <<'EOF'
services:

  angie:

    image: docker.angie.software/angie:latest

    container_name: null-angie

    restart: unless-stopped


    ports:
      - "80:80"
      - "443:443"


    env_file:
      - .env


    volumes:

      - ./angie.conf:/etc/angie/angie.conf:ro

      - ./acme:/var/lib/angie/acme


EOF



cat > angie.conf <<'EOF'

worker_processes auto;


events {
    worker_connections 1024;
}



http {


    acme_client letsencrypt {

        directory https://acme-v02.api.letsencrypt.org/directory;

        email admin@{$DOMAIN};

    }



    server {


        listen 80;

        server_name {$DOMAIN};


        acme letsencrypt;

    }





    server {


        listen 443 ssl http2;

        server_name {$DOMAIN};



        acme_certificate letsencrypt;



        location / {


            proxy_pass http://127.0.0.1:7443;


            proxy_http_version 1.1;


            proxy_set_header Host $host;

            proxy_set_header X-Real-IP $remote_addr;


            proxy_intercept_errors on;


        }



        error_page 400 401 403 404 405 500 502 503 504 = @fake;



        location @fake {


            default_type text/html;


            return 403 "Forbidden";

        }


    }

}

EOF



docker compose up -d


ok "Angie запущен"



echo
echo "============================"
echo "Домен:"
echo "https://$DOMAIN"
echo
echo "Xray:"
echo "http://127.0.0.1:7443"
echo
echo "Каталог:"
echo "$WORKDIR"
echo "============================"
