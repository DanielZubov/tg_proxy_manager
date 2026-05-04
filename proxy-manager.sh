#!/bin/bash

# --- КОНФИГУРАЦИЯ (Telemt Official Standard) ---
BINARY_PATH="/bin/telemt"
CONFIG_DIR="/etc/telemt"
CONFIG_FILE="$CONFIG_DIR/telemt.toml"
SERVICE_FILE="/etc/systemd/system/telemt.service"

# Файлы данных скрипта
PORT_FILE="$CONFIG_DIR/port.conf"
SECRET_FILE="$CONFIG_DIR/secret.conf"
DOMAIN_FILE="$CONFIG_DIR/domain.conf"
TAG_FILE="$CONFIG_DIR/tag.conf"
PUBLIC_HOST_FILE="$CONFIG_DIR/public_host.conf"
USERNAME_FILE="$CONFIG_DIR/username.conf"

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
    mkdir -p "$CONFIG_DIR"
    mkdir -p /opt/telemt/tlsfront
    chown -R telemt:telemt /opt/telemt 2>/dev/null
}

is_port_free() {
    ! ss -tuln | grep -q ":$1 "
}

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

# Расширенная проверка и настройка сети
network_diagnostics() {
    local port=$1
    local public_host=$2
    
    echo -e "\n${CYAN}=== ДИАГНОСТИКА СЕТИ ===${NC}"
    
    # 1. Проверяем все сетевые интерфейсы
    echo -e "\n${YELLOW}[1] Сетевые интерфейсы:${NC}"
    ip addr show | grep -E "inet |state"
    
    # 2. Проверяем маршрутизацию
    echo -e "\n${YELLOW}[2] Проверка маршрута по умолчанию:${NC}"
    ip route show default
    
    # 3. Проверяем, слушается ли порт на всех интерфейсах
    echo -e "\n${YELLOW}[3] Прослушивание порта $port:${NC}"
    ss -tlnp | grep ":$port "
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[+] Порт слушается${NC}"
    else
        echo -e "${RED}[!] Порт НЕ слушается!${NC}"
    fi
    
    # 4. Проверяем файрвол детально
    echo -e "\n${YELLOW}[4] Проверка файрвола:${NC}"
    
    # iptables
    if command -v iptables >/dev/null; then
        echo -e "${BLUE}iptables INPUT правила для порта $port:${NC}"
        iptables -L INPUT -n -v | grep -E "dpt:$port|Chain INPUT"
        if ! iptables -L INPUT -n | grep -q "dpt:$port"; then
            echo -e "${YELLOW}[!] Нет правила для порта $port. Добавляю...${NC}"
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
            echo -e "${GREEN}[+] Правило добавлено${NC}"
        fi
    fi
    
    # nftables
    if command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -q "$port"; then
        echo -e "${BLUE}nftables правила:${NC}"
        nft list ruleset | grep -A2 -B2 "$port"
    fi
    
    # ufw
    if command -v ufw >/dev/null; then
        echo -e "${BLUE}UFW статус:${NC}"
        ufw status verbose 2>/dev/null
        if ufw status | grep -q "active"; then
            ufw allow "$port/tcp" 2>/dev/null
        fi
    fi
    
    # 5. Проверка облачного файрвола (Hetzner, AWS, etc)
    echo -e "\n${YELLOW}[5] Проверка доступности снаружи:${NC}"
    echo -e "${BLUE}Внешний IP: $public_host${NC}"
    
    # Пробуем проверить порт через онлайн-сервис
    local ext_ip=$(curl -s -4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ ! -z "$ext_ip" ]; then
        echo -e "${BLUE}Проверка порта через portchecker.co...${NC}"
        local check_result=$(curl -s --connect-timeout 10 "https://portchecker.co/check?host=$ext_ip&port=$port" 2>/dev/null)
        if echo "$check_result" | grep -q '"open":true'; then
            echo -e "${GREEN}[+] Порт $port открыт снаружи${NC}"
        else
            echo -e "${YELLOW}[!] Порт $port возможно закрыт снаружи${NC}"
            echo -e "${RED}[!] ВАЖНО: Проверьте облачный файрвол!${NC}"
            echo -e "${RED}    - Hetzner: Cloud Console -> Firewall${NC}"
            echo -e "${RED}    - AWS: Security Groups${NC}"
            echo -e "${RED}    - Google Cloud: VPC Network -> Firewall${NC}"
            echo -e "${RED}    - DigitalOcean: Networking -> Firewalls${NC}"
        fi
    fi
    
    # 6. Пинг и traceroute для диагностики
    echo -e "\n${YELLOW}[6] Сетевая связанность:${NC}"
    echo -e "${BLUE}Проверка исходящего соединения...${NC}"
    timeout 3 bash -c "echo >/dev/tcp/8.8.8.8/53" 2>/dev/null && \
        echo -e "${GREEN}[+] Исходящие соединения работают${NC}" || \
        echo -e "${RED}[!] Проблема с исходящими соединениями${NC}"
}

install_binary() {
    echo -e "${YELLOW}[*] Установка бинарника...${NC}"
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq wget tar xxd qrencode openssl curl jq iproute2 host dnsutils net-tools 2>/dev/null
    
    ARCH=$(uname -m)
    LIBC=$(ldd --version 2>&1 | grep -iq musl && echo "musl" || echo "gnu")
    URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz"
    
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    if wget -qO telemt.tar.gz "$URL" 2>/dev/null; then
        tar -xzf telemt.tar.gz 2>/dev/null
        if [ -f telemt ]; then
            mv -f telemt "$BINARY_PATH"
            chmod +x "$BINARY_PATH"
            echo -e "${GREEN}[+] Бинарник установлен${NC}"
        else
            echo -e "${RED}[!] Бинарник не найден в архиве${NC}"
            cd /
            rm -rf "$TMP_DIR"
            return 1
        fi
    else
        echo -e "${RED}[!] Ошибка загрузки${NC}"
        cd /
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    cd /
    rm -rf "$TMP_DIR"
    
    if ! id -u telemt >/dev/null 2>&1; then
        useradd -d /opt/telemt -m -r -U telemt
        echo -e "${GREEN}[+] Пользователь telemt создан${NC}"
    fi
    
    init_dirs
    return 0
}

# Исправленная генерация конфига по образу рабочего сервера
generate_config() {
    local port=$1
    local secret=$2
    local domain=$3
    local tag=$4
    local public_host=$5
    local username=$6
    
    port=$(echo "$port" | grep -oE '[0-9]+')
    
    echo -e "${YELLOW}[*] Создание конфигурации...${NC}"
    
    # Используем формат как на рабочем сервере
    cat > "$CONFIG_FILE" << EOF
### Конфигурационный файл Telemt Proxy

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
listen = "0.0.0.0:9091"
whitelist = ["127.0.0.0/8"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "$domain"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
$username = "$secret"
EOF
    
    if [ $? -eq 0 ]; then
        chown telemt:telemt "$CONFIG_FILE"
        echo -e "${GREEN}[+] Конфиг создан${NC}"
        
        # Показываем ключевые параметры
        echo -e "\n${BLUE}Параметры конфига:${NC}"
        echo -e "  API listen: ${GREEN}0.0.0.0:9091${NC}"
        echo -e "  Пользователь: ${GREEN}$username${NC}"
        echo -e "  log_level: ${GREEN}normal${NC}"
        return 0
    else
        echo -e "${RED}[!] Ошибка создания конфига${NC}"
        return 1
    fi
}

manage_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Telemt Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=$BINARY_PATH $CONFIG_FILE
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable telemt 2>/dev/null
    systemctl restart telemt
    
    sleep 3
    
    if systemctl is-active --quiet telemt; then
        echo -e "${GREEN}[+] Сервис запущен${NC}"
        
        # Проверяем API на разных интерфейсах
        echo -e "${YELLOW}[*] Проверка API...${NC}"
        if curl -s http://127.0.0.1:9091/v1/users >/dev/null 2>&1; then
            echo -e "${GREEN}[+] API доступен на 127.0.0.1${NC}"
        fi
        if curl -s http://0.0.0.0:9091/v1/users >/dev/null 2>&1; then
            echo -e "${GREEN}[+] API доступен на 0.0.0.0${NC}"
        fi
        
        return 0
    else
        echo -e "${RED}[!] Сервис не запустился${NC}"
        journalctl -u telemt -n 20 --no-pager
        return 1
    fi
}

menu_install() {
    clear
    echo -e "${CYAN}=== Установка Telemt Proxy ===${NC}"
    init_dirs

    # 1. Fake TLS домен
    echo -e "\n${YELLOW}Шаг 1: Fake TLS домен${NC}"
    echo "1) google.com"
    echo "2) github.com" 
    echo "3) microsoft.com"
    echo "4) Свой вариант"
    read -p "Выбор (1-4, Enter=google.com): " d_idx
    case $d_idx in
        2) domain="github.com" ;;
        3) domain="microsoft.com" ;;
        4) read -p "Домен: " domain ;;
        *) domain="google.com" ;;
    esac
    echo "$domain" > "$DOMAIN_FILE"
    echo -e "${GREEN}[+] Fake TLS: $domain${NC}"

    # 2. Публичный хост
    echo -e "\n${YELLOW}Шаг 2: Публичный адрес${NC}"
    server_ip=$(curl -s -4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    [ -z "$server_ip" ] && server_ip=$(hostname -I | awk '{print $1}')
    
    echo -e "IP сервера: ${GREEN}$server_ip${NC}"
    read -p "Публичный хост/IP [$server_ip]: " public_host
    public_host=${public_host:-$server_ip}
    
    # Проверка домена
    if [[ "$public_host" =~ [a-zA-Z] ]] && ! [[ "$public_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${YELLOW}[*] Проверка DNS для $public_host...${NC}"
        if host "$public_host" >/dev/null 2>&1; then
            resolved_ip=$(host "$public_host" | awk '/has address/ {print $NF; exit}')
            echo -e "${GREEN}[+] $public_host резолвится в $resolved_ip${NC}"
            if [ "$resolved_ip" != "$server_ip" ]; then
                echo -e "${RED}[!] ВНИМАНИЕ: DNS указывает на $resolved_ip, а сервер имеет IP $server_ip${NC}"
                echo -e "${RED}[!] Клиенты не смогут подключиться!${NC}"
                read -p "Продолжить? (y/N): " cont
                [ "$cont" != "y" ] && return
            fi
        else
            echo -e "${RED}[!] Домен $public_host не резолвится${NC}"
            read -p "Использовать IP вместо домена? (Y/n): " use_ip
            [ "$use_ip" != "n" ] && public_host="$server_ip"
        fi
    fi
    
    echo "$public_host" > "$PUBLIC_HOST_FILE"
    echo -e "${GREEN}[+] Публичный хост: $public_host${NC}"

    # 3. Порт
    echo -e "\n${YELLOW}Шаг 3: Выбор порта${NC}"
    read -p "Порт (Enter для автоподбора): " user_port
    if [ -z "$user_port" ]; then
        free_port=$(find_free_port)
    else
        if is_port_free "$user_port"; then
            free_port=$user_port
        else
            echo -e "${RED}[!] Порт $user_port занят${NC}"
            free_port=$(find_free_port)
        fi
    fi
    echo "$free_port" > "$PORT_FILE"
    echo -e "${GREEN}[+] Порт: $free_port${NC}"

    # 4. Имя пользователя и секреты
    echo -e "\n${YELLOW}Шаг 4: Настройка доступа${NC}"
    read -p "Имя пользователя (Enter=user1): " username
    username=${username:-user1}
    echo "$username" > "$USERNAME_FILE"
    
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    
    tag=$(cat "$TAG_FILE" 2>/dev/null || echo "00000000000000000000000000000000")
    
    echo -e "${GREEN}[+] Пользователь: $username${NC}"
    echo -e "${GREEN}[+] Secret: ${secret:0:16}...${NC}"

    # Установка
    echo -e "\n${CYAN}=== Установка ===${NC}"
    
    install_binary || return 1
    
    if ! generate_config "$free_port" "$secret" "$domain" "$tag" "$public_host" "$username"; then
        echo -e "${RED}[!] Ошибка конфига${NC}"
        return 1
    fi
    
    if ! manage_service; then
        echo -e "${RED}[!] Ошибка запуска${NC}"
        return 1
    fi
    
    # ДИАГНОСТИКА СЕТИ
    network_diagnostics "$free_port" "$public_host"
    
    echo -e "\n${GREEN}=== Установка завершена! ===${NC}"
    echo -e "${CYAN}Конфиг сохранен: $CONFIG_FILE${NC}"
    
    show_data
    read -p "Нажмите Enter..."
}

show_data() {
    if ! systemctl is-active --quiet telemt; then
        echo -e "${RED}[!] Сервис не запущен${NC}"
        return
    fi
    
    echo -e "\n${GREEN}=== Данные для подключения ===${NC}"
    
    # Ждем API
    for i in {1..10}; do
        if curl -s http://127.0.0.1:9091/v1/users >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    
    RAW_DATA=$(curl -s http://127.0.0.1:9091/v1/users)
    if [ -z "$RAW_DATA" ]; then
        echo -e "${RED}[!] API не отвечает${NC}"
        echo -e "${YELLOW}Проверьте: curl http://127.0.0.1:9091/v1/users${NC}"
        return
    fi
    
    echo -e "\n${CYAN}Ссылки для подключения:${NC}"
    echo "$RAW_DATA" | jq -r '.data[] | .links.tls[]' 2>/dev/null | while read link; do
        if [ ! -z "$link" ] && [ "$link" != "null" ]; then
            echo -e "${GREEN}$link${NC}"
            echo ""
            qrencode -t ANSIUTF8 "$link" 2>/dev/null
            echo ""
        fi
    done
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root

while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Telemt Proxy Manager v3.0       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo "1) 🚀 Установить / Обновить"
    echo "2) 📱 Показать QR и ссылки"
    echo "3) 🏷️  Изменить AD TAG"
    echo "4) 📊 Статус и логи"
    echo "5) 🔄 Перезапуск"
    echo "6) 🔍 ДИАГНОСТИКА СЕТИ"
    echo "7) 📝 Показать конфиг"
    echo "8) 🗑️  Удаление"
    echo "0) Выход"
    echo ""
    
    if systemctl is-active --quiet telemt 2>/dev/null; then
        echo -e "${GREEN}● Сервис активен${NC}"
    else
        echo -e "${RED}● Сервис остановлен${NC}"
    fi
    
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_data; read -p "Enter..." ;;
        3) 
            read -p "TAG (32 hex): " nt
            if [ ${#nt} -eq 32 ] && [[ "$nt" =~ ^[0-9a-fA-F]+$ ]]; then
                echo "$nt" > "$TAG_FILE"
                port=$(cat $PORT_FILE)
                secret=$(cat $SECRET_FILE)
                domain=$(cat $DOMAIN_FILE)
                public_host=$(cat $PUBLIC_HOST_FILE)
                username=$(cat $USERNAME_FILE)
                generate_config "$port" "$secret" "$domain" "$nt" "$public_host" "$username"
                systemctl restart telemt
                echo -e "${GREEN}[+] TAG обновлен${NC}"
            else
                echo -e "${RED}[!] Неверный формат TAG${NC}"
            fi
            sleep 2
            ;;
        4) 
            systemctl status telemt --no-pager
            echo -e "\n${YELLOW}Логи:${NC}"
            journalctl -u telemt -n 30 --no-pager
            read -p "Enter..." 
            ;;
        5) 
            systemctl restart telemt
            sleep 2
            systemctl is-active --quiet telemt && \
                echo -e "${GREEN}[+] Перезапущен${NC}" || \
                echo -e "${RED}[!] Ошибка${NC}"
            sleep 1
            ;;
        6)
            port=$(cat $PORT_FILE 2>/dev/null || echo "неизвестен")
            public_host=$(cat $PUBLIC_HOST_FILE 2>/dev/null || echo "неизвестен")
            network_diagnostics "$port" "$public_host"
            read -p "Enter..."
            ;;
        7)
            if [ -f "$CONFIG_FILE" ]; then
                cat "$CONFIG_FILE"
            else
                echo -e "${RED}[!] Конфиг не найден${NC}"
            fi
            read -p "Enter..."
            ;;
        8) 
            echo -e "${RED}Удалить Telemt?${NC}"
            read -p "Введите 'yes': " confirm
            if [ "$confirm" = "yes" ]; then
                systemctl stop telemt 2>/dev/null
                systemctl disable telemt 2>/dev/null
                rm -f "$SERVICE_FILE" "$BINARY_PATH"
                rm -rf "$CONFIG_DIR"
                userdel -r telemt 2>/dev/null
                systemctl daemon-reload
                echo -e "${GREEN}[+] Удалено${NC}"
            fi
            sleep 2
            ;;
        0) exit 0 ;;
    esac
done
