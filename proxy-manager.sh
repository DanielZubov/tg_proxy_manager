#!/bin/bash

# --- КОНФИГУРАЦИЯ (по официальному гайду) ---
BINARY_PATH="/bin/telemt"
CONFIG_DIR="/etc/telemt"
CONFIG_FILE="$CONFIG_DIR/telemt.toml"
SERVICE_FILE="/etc/systemd/system/telemt.service"

# Файлы данных скрипта
IP_FILE="$CONFIG_DIR/host.conf"
PORT_FILE="$CONFIG_DIR/port.conf"
SECRET_FILE="$CONFIG_DIR/secret.conf"
DOMAIN_FILE="$CONFIG_DIR/domain.conf"
TAG_FILE="$CONFIG_DIR/tag.conf"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Ошибка: запустите от root!${NC}"; exit 1; fi
}

is_port_free() {
    ! ss -tuln | grep -q ":$1 "
}

# --- ШАГ 1: УСТАНОВКА БИНАРНИКА (по инструкции) ---
install_binary() {
    echo -e "${YELLOW}[*] Установка зависимостей и бинарника...${NC}"
    apt-get update -qq && apt-get install -y wget tar xxd qrencode openssl curl jq iproute2 >/dev/null 2>&1

    # Официальный метод скачивания из инструкции
    URL="https://github.com/telemt/telemt/releases/latest/download/telemt-$(uname -m)-linux-$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu).tar.gz"
    
    wget -qO- "$URL" | tar -xz
    mv telemt "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    
    # Создание пользователя (Шаг 2 инструкции)
    if ! id -u telemt >/dev/null 2>&1; then
        useradd -d /opt/telemt -m -r -U telemt
    fi
    mkdir -p "$CONFIG_DIR"
    chown -R telemt:telemt "$CONFIG_DIR"
    echo -e "${GREEN}[+] Бинарник установлен в $BINARY_PATH${NC}"
}

# --- ШАГ 2: ГЕНЕРАЦИЯ КОНФИГА (по инструкции) ---
generate_config() {
    local port=$1
    local secret=$2
    local domain=$3
    local tag=$4
    local host=$(cat "$IP_FILE" 2>/dev/null || curl -s -4 https://api.ipify.org)

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
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "$domain"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
tg_user = "$secret"
EOF
    chown telemt:telemt "$CONFIG_FILE"
}

# --- ШАГ 3: СОЗДАНИЕ СЛУЖБЫ (по инструкции) ---
manage_service() {
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=$BINARY_PATH $CONFIG_FILE
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable telemt
    systemctl restart telemt
}

menu_install() {
    clear
    echo -e "${CYAN}=== Установка Telemt (Official Way) ===${NC}"
    
    # Выбор домена
    echo -e "\n${YELLOW}Выберите Fake TLS домен:${NC}"
    echo "1) petrovich.ru (default)"
    echo "2) google.com"
    echo "3) github.com"
    echo "4) Свой вариант"
    read -p "Выбор: " d_idx
    case $d_idx in
        2) domain="google.com" ;;
        3) domain="github.com" ;;
        4) read -p "Введите домен: " domain ;;
        *) domain="petrovich.ru" ;;
    esac
    echo "$domain" > "$DOMAIN_FILE"

    # Выбор порта
    read -p "Введите порт (по умолчанию 443): " port
    port=${port:-443}
    while ! is_port_free "$port"; do
        echo -e "${RED}Порт $port занят!${NC}"
        read -p "Введите другой порт: " port
    done
    echo "$port" > "$PORT_FILE"

    # Генерация секрета
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    
    # Тэг
    tag=$(cat "$TAG_FILE" 2>/dev/null || echo "00000000000000000000000000000000")

    install_binary
    generate_config "$port" "$secret" "$domain" "$tag"
    manage_service
    
    echo -e "${GREEN}[+] Установка завершена!${NC}"
    show_data
    read -p "Нажмите Enter..."
}

show_data() {
    if ! systemctl is-active --quiet telemt; then echo -e "${RED}Сервис не запущен!${NC}"; return; fi
    
    # Получаем ссылку через API (Шаг 7 инструкции)
    # Используем jq для парсинга, как в гайде
    echo -e "\n${GREEN}=== ССЫЛКИ ИЗ API TELEMT ===${NC}"
    curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[] | "Пользователь: \(.username)\nСсылка: \(.links.tls[0])\n"'
    
    # Дублируем QR для удобства
    LINK=$(curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[0].links.tls[0]')
    if [ "$LINK" != "null" ]; then
        qrencode -t ANSIUTF8 "$LINK"
    fi
}

# --- ГЛАВНОЕ МЕНЮ ---
check_root

while true; do
    clear
    echo -e "${CYAN}=== Telemt Manager (Based on Official Guide) ===${NC}"
    echo "1) Установить / Переустановить"
    echo "2) Показать ссылки (API)"
    echo "3) Установить AD TAG"
    echo "4) Статус и Логи"
    echo "5) Удалить (Purge)"
    echo "0) Выход"
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_data; read -p "Enter..." ;;
        3) read -p "Введите AD TAG: " nt; echo "$nt" > "$TAG_FILE"; 
           generate_config "$(cat $PORT_FILE)" "$(cat $SECRET_FILE)" "$(cat $DOMAIN_FILE)" "$nt";
           systemctl restart telemt; echo "Готово"; sleep 1 ;;
        4) systemctl status telemt; echo "--- Последние 20 строк логов ---"; journalctl -u telemt -n 20; read -p "Enter..." ;;
        5) systemctl stop telemt; systemctl disable telemt; rm -rf "$CONFIG_DIR" "$SERVICE_FILE" "$BINARY_PATH"; userdel -r telemt; echo "Очищено"; sleep 1 ;;
        0) exit ;;
    esac
done
