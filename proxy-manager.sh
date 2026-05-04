#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
BINARY_PATH="/usr/local/bin/mtg"
CONFIG_DIR="/etc/mtg-proxy"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/mtg.service"

# Файлы для хранения переменных
IP_FILE="$CONFIG_DIR/host.conf"
TAG_FILE="$CONFIG_DIR/tag.conf"
SECRET_FILE="$CONFIG_DIR/secret.conf"
BOT_SECRET_FILE="$CONFIG_DIR/bot_secret.conf"
PORT_FILE="$CONFIG_DIR/port.conf"
DOMAIN_FILE="$CONFIG_DIR/domain.conf"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- ПРОВЕРКИ ---
check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Ошибка: запустите через sudo!${NC}"; exit 1; fi
    mkdir -p "$CONFIG_DIR" # Создаем папку сразу при запуске
}

install_deps() {
    echo -e "${YELLOW}[*] Проверка зависимостей...${NC}"
    apt-get update && apt-get install -y wget tar xxd qrencode openssl curl
    if [ ! -f "$BINARY_PATH" ]; then
        wget -qO mtg.tar.gz "https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-2.1.7-linux-amd64.tar.gz"
        tar -xof mtg.tar.gz
        mv mtg-*/mtg "$BINARY_PATH"
        chmod +x "$BINARY_PATH"
        rm -rf mtg.tar.gz mtg-*
    fi
}

get_ip() { curl -s -4 https://api.ipify.org || echo "0.0.0.0"; }

generate_toml() {
    local port=$1
    local secret=$2
    local tag=$3
    
    cat <<EOF > "$CONFIG_FILE"
bind-to = "0.0.0.0:$port"
secret = "$secret"
prefer-ipv4 = true

[network]
dns-servers = ["8.8.8.8:53", "8.8.4.4:53"]

[stats]
statsd = ""
prometheus = ""
EOF

    if [ ! -z "$tag" ]; then
        echo "ad-tag = \"$tag\"" >> "$CONFIG_FILE"
    fi
}

manage_service() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=MTG MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=$BINARY_PATH run $CONFIG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtg
    systemctl restart mtg
}

menu_install() {
    clear
    echo -e "${CYAN}--- Установка через TOML Config ---${NC}"
    
    # Сначала создаем папку, на всякий случай
    mkdir -p "$CONFIG_DIR"

    read -p "Fake TLS Домен (default: github.com): " FAKE_DOMAIN
    FAKE_DOMAIN=${FAKE_DOMAIN:-github.com}
    echo "$FAKE_DOMAIN" > "$DOMAIN_FILE"

    read -p "Публичный IP/Домен (Enter = авто): " PUB_HOST
    [ -z "$PUB_HOST" ] && PUB_HOST=$(get_ip)
    echo "$PUB_HOST" > "$IP_FILE"

    PORT=443
    if ss -tuln | grep -q ":$PORT "; then PORT=9443; fi
    read -p "Порт (default: $PORT): " USER_PORT
    PORT=${USER_PORT:-$PORT}
    echo "$PORT" > "$PORT_FILE"

    # Секреты
    BASE_HEX=$(openssl rand -hex 16)
    echo "$BASE_HEX" > "$BOT_SECRET_FILE"
    DOMAIN_HEX=$(echo -n "$FAKE_DOMAIN" | xxd -p | tr -d '\n')
    RAW_SECRET="ee${BASE_HEX}${DOMAIN_HEX}"
    WORK_SECRET=$(printf '%.66s' "${RAW_SECRET}$(printf '0%.0s' {1..66})")
    WORK_SECRET=${WORK_SECRET:0:66}
    echo "$WORK_SECRET" > "$SECRET_FILE"

    TAG=$(cat "$TAG_FILE" 2>/dev/null)
    generate_toml "$PORT" "$WORK_SECRET" "$TAG"
    manage_service
    
    echo -e "${GREEN}[+] Установка завершена!${NC}"
    show_config
    read -p "Enter..."
}

show_config() {
    if ! systemctl is-active --quiet mtg; then echo -e "${RED}Сервис не запущен!${NC}"; return; fi
    
    HOST=$(cat "$IP_FILE" 2>/dev/null || get_ip)
    SECRET=$(cat "$SECRET_FILE" 2>/dev/null)
    BOT_SECRET=$(cat "$BOT_SECRET_FILE" 2>/dev/null)
    PORT=$(cat "$PORT_FILE" 2>/dev/null)
    AD_TAG=$(cat "$TAG_FILE" 2>/dev/null || echo "нет")

    LINK="tg://proxy?server=$HOST&port=$PORT&secret=$SECRET"

    echo -e "\n${GREEN}=== ДАННЫЕ ДЛЯ КЛИЕНТА ===${NC}"
    echo -e "Ссылка: ${CYAN}$LINK${NC}\n"
    qrencode -t ANSIUTF8 "$LINK"
    
    echo -e "${YELLOW}=== ДАННЫЕ ДЛЯ @MTProxybot ===${NC}"
    echo -e "IP: $HOST | Port: $PORT | Secret: $BOT_SECRET"
    echo -e "Tag: $AD_TAG"
    echo "------------------------------------------------"
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root
install_deps

while true; do
    clear
    echo -e "${CYAN}=== MTProto Systemd (TOML Mode Fixed) ===${NC}"
    echo "1) Установить / Переустановить"
    echo "2) Показать данные"
    echo "3) Установить AD TAG"
    echo "4) Логи (journalctl)"
    echo "5) Удалить всё"
    echo "0) Выход"
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_config; read -p "Enter..." ;;
        3) [ -f "$PORT_FILE" ] && menu_set_tag || echo "Сначала установите прокси";;
        4) clear; journalctl -u mtg -n 50 -f ;;
        5) systemctl stop mtg; systemctl disable mtg; rm -rf "$CONFIG_DIR" "$SERVICE_FILE"; echo "Удалено"; sleep 1 ;;
        0) exit ;;
    esac
done
