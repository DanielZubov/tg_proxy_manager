#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
BINARY_PATH="/usr/local/bin/telemt"
CONFIG_DIR="/etc/telemt"
CONFIG_FILE="$CONFIG_DIR/telemt.toml"
SERVICE_FILE="/etc/systemd/system/telemt.service"

IP_FILE="$CONFIG_DIR/host.conf"
TAG_FILE="$CONFIG_DIR/tag.conf"
SECRET_FILE="$CONFIG_DIR/secret.conf"
DOMAIN_FILE="$CONFIG_DIR/domain.conf"
PORT_FILE="$CONFIG_DIR/port.conf"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- СЛУЖЕБНЫЕ ФУНКЦИИ ---

check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Ошибка: запустите через sudo!${NC}"; exit 1; fi
    mkdir -p "$CONFIG_DIR"
}

# Функция проверки порта на занятость
is_port_free() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 1 # Занят
    else
        return 0 # Свободен
    fi
}

# Функция поиска ближайшего свободного порта
find_free_port() {
    local port=$1
    while ! is_port_free "$port"; do
        port=$((port + 1))
    done
    echo "$port"
}

install_deps() {
    local deps=(wget tar xxd qrencode openssl curl iproute2)
    local to_install=()
    for dep in "${deps[@]}"; do
        if ! type -p "$dep" >/dev/null 2>&1; then to_install+=("$dep"); fi
    done
    if [ ${#to_install[@]} -ne 0 ]; then
        echo -e "${YELLOW}[*] Установка зависимостей...${NC}"
        apt-get update -qq && apt-get install -y "${to_install[@]}" >/dev/null 2>&1
    fi
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${YELLOW}[*] Загрузка Telemt...${NC}"
        wget -qO telemt.tar.gz "https://github.com/hiddify/telemt/releases/latest/download/telemt-linux-amd64.tar.gz"
        tar -xof telemt.tar.gz
        mv telemt "$BINARY_PATH" && chmod +x "$BINARY_PATH"
        rm -rf telemt.tar.gz
    fi
}

# --- ГЕНЕРАЦИЯ ---

generate_config() {
    local port=$1
    local secret=$2
    local tag=$3
    local host=$(cat "$IP_FILE" 2>/dev/null || curl -s -4 https://api.ipify.org)
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
    systemctl enable telemt && systemctl restart telemt
}

# --- ИНТЕРФЕЙС ---

menu_install() {
    clear
    echo -e "${CYAN}=== Установка и настройка Telemt ===${NC}\n"

    # 1. Выбор домена
    echo -e "${YELLOW}Выберите домен для Fake TLS маскировки:${NC}"
    echo "1) google.com"
    echo "2) cloudflare.com"
    echo "3) github.com"
    echo "4) microsoft.com"
    echo "5) Свой вариант"
    read -p "Ваш выбор [1-5]: " dom_choice
    case $dom_choice in
        1) domain="google.com" ;;
        2) domain="cloudflare.com" ;;
        3) domain="github.com" ;;
        4) domain="microsoft.com" ;;
        5) read -p "Введите свой домен: " domain ;;
        *) domain="google.com" ;;
    esac
    echo "$domain" > "$DOMAIN_FILE"

    # 2. Выбор порта
    echo -e "\n${YELLOW}Настройка порта:${NC}"
    default_port=443
    if ! is_port_free 443; then
        default_port=9443
        echo -e "${RED}Порт 443 занят.${NC} Предлагаю: $default_port"
    fi
    
    read -p "Введите порт (Enter для $default_port): " user_port
    user_port=${user_port:-$default_port}
    
    if ! is_port_free "$user_port"; then
        echo -e "${YELLOW}Порт $user_port тоже занят. Ищу ближайший свободный...${NC}"
        user_port=$(find_free_port "$user_port")
        echo -e "${GREEN}Выбран свободный порт: $user_port${NC}"
    fi
    echo "$user_port" > "$PORT_FILE"

    # 3. IP и Секреты
    host=$(curl -s -4 https://api.ipify.org)
    echo "$host" > "$IP_FILE"
    
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"

    tag=$(cat "$TAG_FILE" 2>/dev/null || echo "00000000000000000000000000000000")
    
    generate_config "$user_port" "$secret" "$tag"
    manage_service
    
    echo -e "\n${GREEN}[+] Установка завершена!${NC}"
    show_data
    read -p "Нажмите Enter для возврата в меню..."
}

show_data() {
    if ! systemctl is-active --quiet telemt; then echo -e "${RED}Сервис не запущен!${NC}"; return; fi
    
    host=$(cat "$IP_FILE")
    port=$(cat "$PORT_FILE")
    clean_secret=$(cat "$SECRET_FILE")
    domain=$(cat "$DOMAIN_FILE")
    
    domain_hex=$(echo -n "$domain" | xxd -p | tr -d '\n')
    full_secret="ee${clean_secret}${domain_hex}"
    link="tg://proxy?server=$host&port=$port&secret=$full_secret"

    echo -e "\n${GREEN}=== ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ ===${NC}"
    echo -e "Хост: ${CYAN}$host${NC}"
    echo -e "Порт: ${CYAN}$port${NC}"
    echo -e "Секрет: ${CYAN}$full_secret${NC}"
    echo -e "Маскировка под: ${YELLOW}$domain${NC}"
    echo -e "\nСсылка: ${MAGENTA}$link${NC}\n"
    qrencode -t ANSIUTF8 "$link"
}

# --- ЦИКЛ МЕНЮ ---
check_root
install_deps

while true; do
    clear
    echo -e "${CYAN}=== Telemt MTProto Manager ===${NC}"
    echo "1) Установить / Обновить (с выбором порта и TLS)"
    echo "2) Показать QR и Данные"
    echo "3) Установить AD TAG"
    echo "4) Просмотр логов"
    echo "5) Удалить всё"
    echo "0) Выход"
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_data; read -p "Enter..." ;;
        3) [ -f "$PORT_FILE" ] && (read -p "Введите тег: " nt; echo "$nt" > "$TAG_FILE"; generate_config "$(cat $PORT_FILE)" "$(cat $SECRET_FILE)" "$nt"; systemctl restart telemt; echo "Тег изменен!") || echo "Сначала установите прокси"; sleep 1 ;;
        4) clear; journalctl -u telemt -n 50 -f ;;
        5) systemctl stop telemt; systemctl disable telemt; rm -rf "$CONFIG_DIR" "$SERVICE_FILE" "$BINARY_PATH"; echo "Удалено"; sleep 1 ;;
        0) exit ;;
    esac
done
