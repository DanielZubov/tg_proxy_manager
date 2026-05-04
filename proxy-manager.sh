#!/bin/bash

# --- КОНФИГУРАЦИЯ (Telemt Official Standard) ---
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
PUBLIC_HOST_FILE="$CONFIG_DIR/public_host.conf"

# Приоритетные порты для автоподбора
PREFERRED_PORTS=(443 8443 9443 8444 9444 8080 8880 4433 4443 4343)

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- СЛУЖЕБНЫЕ ФУНКЦИИ ---

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Ошибка: запустите от root!${NC}"
        exit 1
    fi
}

init_dirs() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
    fi
    # Создаем tlsfront если его нет (нужно для маскировки)
    mkdir -p /opt/telemt/tlsfront
}

is_port_free() {
    ! ss -tuln | grep -q ":$1 "
}

# Исправленная функция: пишет логи в stderr, а результат (порт) в stdout
find_free_port() {
    echo -e "${YELLOW}[*] Поиск свободного порта...${NC}" >&2
    for port in "${PREFERRED_PORTS[@]}"; do
        if is_port_free "$port"; then
            echo "$port"
            return 0
        fi
    done
    
    for port in $(seq 10000 11000); do
        if is_port_free "$port"; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

check_firewall() {
    local port=$1
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$port/tcp" >/dev/null 2>&1
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$port/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

validate_public_host() {
    local host=$1
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then return 0; fi
    if [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        return 0
    fi
    return 1
}

install_binary() {
    echo -e "${YELLOW}[*] Обновление системы и установка зависимостей...${NC}"
    apt-get update -qq && apt-get install -y -qq wget tar xxd qrencode openssl curl jq iproute2 host dnsutils >/dev/null 2>&1
    
    ARCH=$(uname -m)
    LIBC=$(ldd --version 2>&1 | grep -iq musl && echo "musl" || echo "gnu")
    URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz"
    
    echo -e "${YELLOW}[*] Скачивание бинарника...${NC}"
    wget -qO- "$URL" | tar -xz -C /tmp/
    mv -f /tmp/telemt "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    
    if ! id -u telemt >/dev/null 2>&1; then
        useradd -d /opt/telemt -m -r -U telemt
    fi
    chown -R telemt:telemt "$CONFIG_DIR" /opt/telemt
}

generate_config() {
    local port=$1
    local secret=$2
    local domain=$3
    local tag=$4
    local public_host=$5
    
    # Жесткая очистка порта от любого текста (только цифры)
    port=$(echo "$port" | grep -oE '[0-9]+')

    cat > "$CONFIG_FILE" << EOF
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
public_host = "$public_host"
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

manage_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Telemt Proxy Service
After=network-online.target

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

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable telemt >/dev/null 2>&1
    systemctl restart telemt
}

menu_install() {
    clear
    echo -e "${CYAN}=== Установка Telemt Proxy ===${NC}"
    init_dirs

    # Домен
    read -p "Fake TLS домен (default: petrovich.ru): " domain
    domain=${domain:-petrovich.ru}
    echo "$domain" > "$DOMAIN_FILE"

    # Хост
    server_ip=$(curl -s -4 https://api.ipify.org || hostname -I | awk '{print $1}')
    read -p "Публичный IP или домен (default: $server_ip): " public_host
    public_host=${public_host:-$server_ip}
    echo "$public_host" > "$PUBLIC_HOST_FILE"

    # Порт
    read -p "Желаемый порт (пусто для автоподбора): " user_port
    if [ -z "$user_port" ]; then
        free_port=$(find_free_port)
    else
        free_port=$user_port
    fi
    echo "$free_port" > "$PORT_FILE"
    check_firewall "$free_port"

    # Секреты
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    tag=$(cat "$TAG_FILE" 2>/dev/null || echo "00000000000000000000000000000000")

    install_binary
    generate_config "$free_port" "$secret" "$domain" "$tag" "$public_host"
    manage_service
    
    echo -e "${GREEN}[+] Установка завершена на порту $free_port!${NC}"
    sleep 2
    show_data
    read -p "Нажмите Enter..."
}

show_data() {
    clear
    echo -e "${GREEN}=== Данные для подключения ===${NC}"
    if ! curl -s http://127.0.0.1:9091/v1/users >/dev/null; then
        echo -e "${YELLOW}[!] Ожидание запуска API...${NC}"
        sleep 3
    fi
    
    RAW_DATA=$(curl -s http://127.0.0.1:9091/v1/users)
    LINK=$(echo "$RAW_DATA" | jq -r '.data[0].links.tls[0]' 2>/dev/null)
    
    if [ ! -z "$LINK" ] && [ "$LINK" != "null" ]; then
        echo -e "${CYAN}$LINK${NC}\n"
        qrencode -t ANSIUTF8 "$LINK"
    else
        echo -e "${RED}[!] Ссылка не получена. Проверьте логи (пункт 4).${NC}"
    fi
}

# --- ЦИКЛ ---
check_root
while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      Telemt Proxy Manager v2.2       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo "1) 🚀 Установить / Обновить"
    echo "2) 📱 Показать QR и ссылки"
    echo "3) 🏷️  Изменить AD TAG"
    echo "4) 📊 Статус и логи"
    echo "5) 🔄 Перезапуск"
    echo "8) 🗑️  Удаление"
    echo "0) Выход"
    echo ""
    systemctl is-active --quiet telemt && echo -e "${GREEN}● Сервис работает${NC}" || echo -e "${RED}● Сервис остановлен${NC}"
    
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_data; read -p "Enter..." ;;
        3) read -p "TAG (32 hex): " nt; [ ${#nt} -eq 32 ] && echo "$nt" > "$TAG_FILE" && \
           generate_config "$(cat $PORT_FILE)" "$(cat $SECRET_FILE)" "$(cat $DOMAIN_FILE)" "$nt" "$(cat $PUBLIC_HOST_FILE)" && \
           systemctl restart telemt ;;
        4) systemctl status telemt; journalctl -u telemt -n 20 --no-pager; read -p "Enter..." ;;
        5) systemctl restart telemt ;;
        8) systemctl stop telemt; rm -rf "$CONFIG_DIR" "$SERVICE_FILE" "$BINARY_PATH"; echo "Удалено"; sleep 2 ;;
        0) exit 0 ;;
    esac
done
