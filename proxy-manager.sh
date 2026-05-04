#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
BINARY_URL="https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-2.1.7-linux-amd64.tar.gz"
BINARY_PATH="/usr/local/bin/mtg"
SERVICE_FILE="/etc/systemd/system/mtg.service"
CONFIG_DIR="/etc/mtg-proxy"
IP_FILE="$CONFIG_DIR/host.conf"
TAG_FILE="$CONFIG_DIR/tag.conf"
SECRET_FILE="$CONFIG_DIR/secret.conf"
BOT_SECRET_FILE="$CONFIG_DIR/bot_secret.conf"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- ИНИЦИАЛИЗАЦИЯ ---
mkdir -p "$CONFIG_DIR"

check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Ошибка: запустите через sudo!${NC}"; exit 1; fi
}

# Функция скачивания и установки бинарника
install_mtg() {
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${YELLOW}[*] Скачивание и установка mtg...${NC}"
        apt-get update && apt-get install -y wget tar xxd qrencode openssl
        wget -qO mtg.tar.gz "$BINARY_URL"
        tar -xof mtg.tar.gz
        mv mtg-*/mtg "$BINARY_PATH"
        chmod +x "$BINARY_PATH"
        rm -rf mtg.tar.gz mtg-*
        echo -e "${GREEN}[+] mtg успешно установлен в $BINARY_PATH${NC}"
    fi
}

get_ip() { curl -s -4 https://api.ipify.org || echo "0.0.0.0"; }

show_config() {
    if ! systemctl is-active --quiet mtg; then echo -e "${RED}Сервис не запущен!${NC}"; return; fi
    
    HOST=$(cat "$IP_FILE" 2>/dev/null || get_ip)
    SECRET=$(cat "$SECRET_FILE" 2>/dev/null)
    BOT_SECRET=$(cat "$BOT_SECRET_FILE" 2>/dev/null)
    PORT=$(grep -oP '(?<=:)\d+(?= )' "$SERVICE_FILE" | head -n 1)

    LINK="tg://proxy?server=$HOST&port=$PORT&secret=$SECRET"

    echo -e "\n${GREEN}=== ДАННЫЕ ДЛЯ КЛИЕНТА ===${NC}"
    echo -e "Ссылка: ${CYAN}$LINK${NC}\n"
    qrencode -t ANSIUTF8 "$LINK"
    
    echo -e "${YELLOW}=== ДАННЫЕ ДЛЯ @MTProxybot ===${NC}"
    echo -e "IP: $HOST | Port: $PORT | Secret: $BOT_SECRET"
    echo -e "Tag в системе: $(cat "$TAG_FILE" 2>/dev/null || echo "нет")"
    echo "------------------------------------------------"
}

manage_service() {
    local port=$1
    local secret=$2
    local tag=$3
    
    # Используем полный флаг --ad-tag вместо короткого -t, 
    # чтобы mtg не путал его с тайм-аутом.
    PROMO_ARG=""
    [ ! -z "$tag" ] && PROMO_ARG="--ad-tag=$tag"

    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=MTG MTProto Proxy
After=network.target

[Service]
Type=simple
# Явно задаем bind через -b и используем длинные флаги для надежности
ExecStart=$BINARY_PATH simple-run -n 1.1.1.1 -i prefer-ipv4 $PROMO_ARG -b 0.0.0.0:$port $secret
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtg
    systemctl restart mtg
    echo -e "${GREEN}[+] Сервис mtg перезапущен с исправленными флагами!${NC}"
}

menu_install() {
    clear
    echo -e "${CYAN}--- Быстрая настройка прокси ---${NC}"
    
    # Пытаемся остановить докер версию если она есть
    docker stop mtproto-proxy &>/dev/null && docker rm mtproto-proxy &>/dev/null

    read -p "Домен для маскировки (default: max.ru): " FAKE_DOMAIN
    FAKE_DOMAIN=${FAKE_DOMAIN:-max.ru}
    
    read -p "Публичный домен/IP (Enter = авто): " PUB_HOST
    [ -z "$PUB_HOST" ] && PUB_HOST=$(get_ip)
    echo "$PUB_HOST" > "$IP_FILE"

    PORT=443
    if ss -tuln | grep -q ":$PORT "; then PORT=9443; fi
    read -p "Порт (default: $PORT): " USER_PORT
    PORT=${USER_PORT:-$PORT}

    # Генерация секретов (Правильный 64-символьный Fake TLS)
    BASE_HEX=$(openssl rand -hex 16)
    echo "$BASE_HEX" > "$BOT_SECRET_FILE"
    
    DOMAIN_HEX=$(echo -n "$FAKE_DOMAIN" | xxd -p | tr -d '\n')
    RAW_SECRET="ee${BASE_HEX}${DOMAIN_HEX}"
    WORK_SECRET=$(printf '%.66s' "${RAW_SECRET}$(printf '0%.0s' {1..66})")
    WORK_SECRET=${WORK_SECRET:0:66}
    echo "$WORK_SECRET" > "$SECRET_FILE"

    manage_service "$PORT" "$WORK_SECRET" ""
    show_config
    read -p "Нажмите Enter..."
}

menu_set_tag() {
    clear
    echo -e "${MAGENTA}--- Привязка канала (AD TAG) ---${NC}"
    read -p "Введите TAG от @MTProxybot: " NEW_TAG
    if [ ! -z "$NEW_TAG" ]; then
        echo "$NEW_TAG" > "$TAG_FILE"
        PORT=$(grep -oP '(?<=:)\d+(?= )' "$SERVICE_FILE" | head -n 1)
        SECRET=$(cat "$SECRET_FILE")
        manage_service "$PORT" "$SECRET" "$NEW_TAG"
    else
        echo "Тег не введен."
        sleep 1
    fi
}

# --- ЗАПУСК ---
check_root
install_mtg

while true; do
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e "      MTProto Proxy Systemd Manager   "
    echo -e "${BLUE}======================================${NC}"
    echo "1) Установить / Обновить прокси"
    echo "2) Показать данные для клиента и бота"
    echo "3) Добавить/Изменить AD TAG (промо-канал)"
    echo "4) Посмотреть логи (диагностика)"
    echo "5) Удалить прокси из системы"
    echo "0) Выход"
    echo "--------------------------------------"
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_config; read -p "Нажмите Enter..." ;;
        3) menu_set_tag ;;
        4) clear; echo "Логи (для выхода нажмите Ctrl+C):"; journalctl -u mtg -n 50 -f ;;
        5) systemctl stop mtg; systemctl disable mtg; rm -rf "$SERVICE_FILE" "$CONFIG_DIR" "$BINARY_PATH"; echo "Всё удалено"; sleep 1 ;;
        0) exit ;;
    esac
done
