#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
BINARY_PATH="/usr/local/bin/telemt"
CONFIG_DIR="/etc/telemt"
CONFIG_FILE="$CONFIG_DIR/telemt.toml"
SERVICE_FILE="/etc/systemd/system/telemt.service"

# Хранилище настроек
IP_FILE="$CONFIG_DIR/host.conf"
TAG_FILE="$CONFIG_DIR/tag.conf"
SECRET_FILE="$CONFIG_DIR/secret.conf"       # Чистый 32-hex секрет
DOMAIN_FILE="$CONFIG_DIR/domain.conf"
PORT_FILE="$CONFIG_DIR/port.conf"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- СИСТЕМНЫЕ ПРОВЕРКИ ---

check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Ошибка: запустите через sudo!${NC}"; exit 1; fi
    mkdir -p "$CONFIG_DIR"
}

install_deps() {
    local deps=(wget tar xxd qrencode openssl curl)
    local to_install=()

    for dep in "${deps[@]}"; do
        if ! type -p "$dep" >/dev/null 2>&1; then to_install+=("$dep"); fi
    done

    if [ ${#to_install[@]} -ne 0 ]; then
        echo -e "${YELLOW}[*] Установка зависимостей: ${to_install[*]}...${NC}"
        apt-get update -qq && apt-get install -y "${to_install[@]}" >/dev/null 2>&1
    fi

    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${YELLOW}[*] Загрузка Telemt...${NC}"
        # Ссылка на актуальный релиз telemt (подправьте версию если вышла новее)
        wget -qO telemt.tar.gz "https://github.com/hiddify/telemt/releases/latest/download/telemt-linux-amd64.tar.gz"
        tar -xof telemt.tar.gz
        mv telemt "$BINARY_PATH"
        chmod +x "$BINARY_PATH"
        rm -rf telemt.tar.gz
        echo -e "${GREEN}[+] Telemt успешно установлен.${NC}"
    fi
}

get_ip() { curl -s -4 https://api.ipify.org || echo "0.0.0.0"; }

# --- ГЕНЕРАЦИЯ КОНФИГА TELEMT ---

generate_config() {
    local port=$1
    local secret=$2 # Ожидаем чистый hex (32 символа)
    local tag=$3
    local host=$(cat "$IP_FILE" 2>/dev/null || get_ip)
    local domain=$(cat "$DOMAIN_FILE" 2>/dev/null || echo "google.com")

    cat <<EOF > "$CONFIG_FILE"
[general]
use_middle_proxy = true
ad_tag = "$tag"
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "$host"
public_port = $port

[server]
port = $port

[server.api]
enabled = false

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "$domain"
mask = true
tls_emulation = true
tls_front_dir = "$CONFIG_DIR/tlsfront"

[access.users]
tg_user = "$secret"
EOF
    mkdir -p "$CONFIG_DIR/tlsfront"
}

manage_service() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Telemt MTProto Proxy
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$BINARY_PATH -c $CONFIG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable telemt
    systemctl restart telemt
}

# --- МЕНЮ ---

show_data() {
    if ! systemctl is-active --quiet telemt; then echo -e "${RED}Сервис не запущен!${NC}"; return; fi
    
    local host=$(cat "$IP_FILE")
    local port=$(cat "$PORT_FILE")
    local clean_secret=$(cat "$SECRET_FILE")
    local domain=$(cat "$DOMAIN_FILE")
    
    # Генерация ee-секрета для ссылки
    local domain_hex=$(echo -n "$domain" | xxd -p | tr -d '\n')
    local full_secret="ee${clean_secret}${domain_hex}"
    
    local link="tg://proxy?server=$host&port=$port&secret=$full_secret"

    echo -e "\n${GREEN}=== ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ ===${NC}"
    echo -e "IP: ${CYAN}$host${NC} | Порт: ${CYAN}$port${NC}"
    echo -e "Секрет: ${CYAN}$full_secret${NC}"
    echo -e "\nСсылка: ${MAGENTA}$link${NC}\n"
    qrencode -t ANSIUTF8 "$link"
    
    echo -e "${YELLOW}Для @MTProxybot:${NC}"
    echo -e "IP: $host | Port: $port | Secret (для бота): $clean_secret"
    echo "------------------------------------------------"
}

menu_install() {
    clear
    echo -e "${CYAN}--- Установка Telemt ---${NC}"
    
    read -p "Fake TLS Домен (default: google.com): " domain
    domain=${domain:-google.com}
    echo "$domain" > "$DOMAIN_FILE"

    read -p "Публичный IP (Enter для авто): " host
    [ -z "$host" ] && host=$(get_ip)
    echo "$host" > "$IP_FILE"

    read -p "Порт (default: 443): " port
    port=${port:-443}
    echo "$port" > "$PORT_FILE"

    # Генерируем чистый 32-hex секрет
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"

    tag=$(cat "$TAG_FILE" 2>/dev/null || echo "00000000000000000000000000000000")
    
    generate_config "$port" "$secret" "$tag"
    manage_service
    
    echo -e "${GREEN}[+] Telemt запущен!${NC}"
    show_data
    read -p "Нажмите Enter..."
}

menu_set_tag() {
    clear
    read -p "Введите AD TAG от @MTProxybot: " new_tag
    if [ ! -z "$new_tag" ]; then
        echo "$new_tag" > "$TAG_FILE"
        generate_config "$(cat $PORT_FILE)" "$(cat $SECRET_FILE)" "$new_tag"
        systemctl restart telemt
        echo "Тег обновлен."
    fi
    sleep 1
}

# --- ЗАПУСК ---
check_root
install_deps

while true; do
    clear
    echo -e "${CYAN}=== Управление Telemt Proxy ===${NC}"
    echo "1) Установить / Переустановить"
    echo "2) Показать данные для подключения"
    echo "3) Установить AD TAG"
    echo "4) Логи (мониторинг)"
    echo "5) Полное удаление"
    echo "0) Выход"
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_data; read -p "Enter..." ;;
        3) [ -f "$PORT_FILE" ] && menu_set_tag || (echo "Сначала установите прокси"; sleep 1);;
        4) clear; journalctl -u telemt -n 50 -f ;;
        5) systemctl stop telemt; systemctl disable telemt; rm -rf "$CONFIG_DIR" "$SERVICE_FILE" "$BINARY_PATH"; echo "Удалено"; sleep 1 ;;
        0) exit ;;
    esac
done
