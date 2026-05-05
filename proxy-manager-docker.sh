#!/bin/bash

# --- КОНФИГУРАЦИЯ (Telemt Docker) ---
DOCKER_DIR="/opt/telemt"
CONFIG_FILE="$DOCKER_DIR/config.toml"
DOCKER_COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

# Файлы данных скрипта
PORT_FILE="$DOCKER_DIR/port.conf"
SECRET_FILE="$DOCKER_DIR/secret.conf"
DOMAIN_FILE="$DOCKER_DIR/domain.conf"
PUBLIC_HOST_FILE="$DOCKER_DIR/public_host.conf"
USERNAME_FILE="$DOCKER_DIR/username.conf"
TAG_FILE="$DOCKER_DIR/tag.conf"

# Приоритетные порты
PREFERRED_PORTS=(9444 8444 9443 8443 8080 8880 4343 4443 7443 6443)

# Популярные домены
POPULAR_DOMAINS=(
    "google.com"
    "cloudflare.com"
    "microsoft.com"
    "github.com"
    "apple.com"
    "yandex.ru"
    "vk.com"
    "mail.ru"
    "ok.ru"
    "rambler.ru"
    "kaspersky.ru"
)

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- ОПРЕДЕЛЕНИЕ КОМАНДЫ DOCKER COMPOSE ---
DOCKER_COMPOSE_CMD=""

detect_docker_compose() {
    # Проверяем новую команду docker compose (без дефиса)
    if docker compose version &>/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
        echo -e "${GREEN}[+] Использую 'docker compose'${NC}"
        return 0
    fi
    
    # Проверяем старую команду docker-compose (с дефисом)
    if command -v docker-compose &>/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
        echo -e "${GREEN}[+] Использую 'docker-compose'${NC}"
        return 0
    fi
    
    echo -e "${RED}[!] Docker Compose не найден!${NC}"
    return 1
}

# Функция-обертка для выполнения docker compose команд
docker_compose() {
    cd "$DOCKER_DIR"
    $DOCKER_COMPOSE_CMD "$@"
}

# --- СЛУЖЕБНЫЕ ФУНКЦИИ ---

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Ошибка: запустите от root!${NC}"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}[*] Установка Docker...${NC}"
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        echo -e "${GREEN}[+] Docker установлен${NC}"
    fi
    
    # Проверяем версию Docker
    DOCKER_VERSION=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
    echo -e "${BLUE}[*] Версия Docker: $DOCKER_VERSION${NC}"
    
    # Устанавливаем Docker Compose если нужно
    if ! docker compose version &>/dev/null 2>&1 && ! command -v docker-compose &>/dev/null; then
        echo -e "${YELLOW}[*] Установка Docker Compose...${NC}"
        
        # Определяем архитектуру
        ARCH=$(uname -m)
        if [ "$ARCH" = "x86_64" ]; then
            COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-Linux-x86_64"
        elif [ "$ARCH" = "aarch64" ]; then
            COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-Linux-aarch64"
        else
            # Если не можем определить, ставим через apt
            apt-get update -qq
            apt-get install -y -qq docker-compose
        fi
        
        if [ ! -z "$COMPOSE_URL" ]; then
            curl -L "$COMPOSE_URL" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        fi
        
        echo -e "${GREEN}[+] Docker Compose установлен${NC}"
    fi
    
    # Определяем какую команду использовать
    detect_docker_compose
}

install_deps() {
    echo -e "${YELLOW}[*] Установка зависимостей...${NC}"
    apt-get update -qq
    apt-get install -y -qq qrencode curl wget jq ufw dnsutils 2>/dev/null
    echo -e "${GREEN}[+] Зависимости установлены${NC}"
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
    
    echo -e "${RED}[!] Не найден свободный порт!${NC}" >&2
    return 1
}

validate_domain() {
    local domain=$1
    if [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_ip_or_domain() {
    local input=$1
    if [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    if [[ "$input" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

network_diagnostics() {
    local port=$1
    local public_host=$2
    
    echo -e "\n${CYAN}=== ДИАГНОСТИКА СЕТИ ===${NC}"
    
    echo -e "\n${YELLOW}[1] Проверка порта $port:${NC}"
    ss -tlnp | grep ":$port "
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[+] Порт слушается Docker'ом${NC}"
    else
        echo -e "${RED}[!] Порт НЕ слушается!${NC}"
    fi
    
    echo -e "\n${YELLOW}[2] Проверка файрвола:${NC}"
    
    if command -v ufw >/dev/null && ufw status | grep -q "active"; then
        if ! ufw status | grep -q "$port"; then
            echo -e "${BLUE}Добавляю правило в UFW...${NC}"
            ufw allow "$port/tcp"
            ufw allow "$port/udp"
            echo -e "${GREEN}[+] UFW правила добавлены${NC}"
        else
            echo -e "${GREEN}[+] UFW правило уже есть${NC}"
        fi
    fi
    
    if command -v iptables >/dev/null; then
        if ! iptables -L INPUT -n | grep -q "dpt:$port"; then
            echo -e "${BLUE}Добавляю правило в iptables...${NC}"
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT
            echo -e "${GREEN}[+] iptables правила добавлены${NC}"
        fi
    fi
    
    echo -e "\n${YELLOW}[3] Проверка DNS резолвинга:${NC}"
    if [[ "$public_host" =~ [a-zA-Z] ]] && ! [[ "$public_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local resolved=$(dig +short "$public_host" A 2>/dev/null | head -1)
        if [ ! -z "$resolved" ]; then
            echo -e "${GREEN}[+] $public_host → $resolved${NC}"
        else
            echo -e "${RED}[!] $public_host не резолвится!${NC}"
        fi
    fi
    
    echo -e "\n${YELLOW}[4] Статус контейнера:${NC}"
    docker ps --filter name=telemt --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    echo -e "\n${YELLOW}[5] Версия Docker Compose:${NC}"
    $DOCKER_COMPOSE_CMD version 2>/dev/null || echo -e "${RED}Docker Compose не найден${NC}"
}

generate_docker_compose() {
    local port=$1
    
    echo -e "${YELLOW}[*] Создание docker-compose.yml...${NC}"
    
    cat > "$DOCKER_COMPOSE_FILE" << EOF
version: '3.8'

services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "${port}:${port}"
    command: ["/etc/telemt/telemt.toml"]
    volumes:
      - ./config.toml:/etc/telemt/telemt.toml:ro
    environment:
      RUST_LOG: info
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
EOF
    
    # Добавляем version только для старых версий
    if [[ "$DOCKER_COMPOSE_CMD" == "docker-compose" ]]; then
        sed -i '1i version: "3.8"\n' "$DOCKER_COMPOSE_FILE"
    fi
    
    echo -e "${GREEN}[+] docker-compose.yml создан${NC}"
}

generate_config() {
    local port=$1
    local secret=$2
    local domain=$3
    local tag=$4
    local public_host=$5
    local username=$6
    
    echo -e "${YELLOW}[*] Создание конфигурации telemt.toml...${NC}"
    
    cat > "$CONFIG_FILE" << EOF
### Telemt Based Config.toml

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
whitelist = ["127.0.0.1/32", "::1/128"]
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
        echo -e "${GREEN}[+] Конфигурация создана${NC}"
        return 0
    else
        echo -e "${RED}[!] Ошибка создания конфига${NC}"
        return 1
    fi
}

start_docker_container() {
    echo -e "${YELLOW}[*] Запуск Docker контейнера...${NC}"
    
    cd "$DOCKER_DIR"
    docker_compose down 2>/dev/null
    docker_compose up -d
    
    echo -e "${YELLOW}[*] Ожидание запуска (10 секунд)...${NC}"
    sleep 10
    
    if docker ps | grep -q telemt; then
        echo -e "${GREEN}[+] Контейнер успешно запущен${NC}"
        return 0
    else
        echo -e "${RED}[!] Ошибка запуска контейнера${NC}"
        docker_compose logs --tail=30
        return 1
    fi
}

show_qr() {
    local link=$1
    echo -e "\n${YELLOW}📱 QR Code:${NC}"
    echo "$link" | qrencode -t ANSIUTF8 2>/dev/null
    echo ""
}

show_data() {
    if ! docker ps | grep -q telemt; then
        echo -e "${RED}[!] Контейнер не запущен${NC}"
        return
    fi
    
    echo -e "\n${GREEN}=== ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ ===${NC}"
    
    LINK=$(docker logs telemt 2>&1 | grep -oE 'tg://proxy[^[:space:]]+' | head -1)
    
    if [ ! -z "$LINK" ]; then
        echo -e "\n${CYAN}📱 Ссылка для Telegram:${NC}"
        echo -e "${GREEN}$LINK${NC}"
        show_qr "$LINK"
        
        if [ -f "$PUBLIC_HOST_FILE" ] && [ -f "$PORT_FILE" ] && [ -f "$SECRET_FILE" ]; then
            HOST=$(cat "$PUBLIC_HOST_FILE")
            PORT=$(cat "$PORT_FILE")
            SECRET=$(cat "$SECRET_FILE")
            echo -e "\n${CYAN}📋 Данные для ручной настройки:${NC}"
            echo -e "  ${BLUE}HOST:${NC} $HOST"
            echo -e "  ${BLUE}PORT:${NC} $PORT"
            echo -e "  ${BLUE}SECRET:${NC} $SECRET"
            
            echo -e "\n${CYAN}📢 Для настройки промо канала:${NC}"
            echo -e "  ${BLUE}HOST:PORT${NC} $HOST:$PORT"
            echo -e "  ${BLUE}Secret:${NC} $SECRET"
        fi
    else
        echo -e "${YELLOW}[!] Ссылка еще не сгенерирована${NC}"
        echo -e "${BLUE}Проверьте логи: docker logs telemt --tail=30${NC}"
    fi
}

show_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}=== СОДЕРЖИМОЕ КОНФИГА ===${NC}"
        cat "$CONFIG_FILE"
    else
        echo -e "${RED}[!] Конфиг не найден${NC}"
    fi
}

menu_install() {
    clear
    echo -e "${CYAN}=== Установка Telemt Proxy (Docker) ===${NC}"
    
    check_docker
    install_deps
    
    mkdir -p "$DOCKER_DIR"
    cd "$DOCKER_DIR"
    
    docker_compose down 2>/dev/null

    # Шаг 1: Fake TLS домен
    echo -e "\n${YELLOW}Шаг 1: Fake TLS домен${NC}"
    echo "Выберите домен или укажите свой:"
    local i=1
    for domain in "${POPULAR_DOMAINS[@]}"; do
        echo "  $i) $domain"
        ((i++))
    done
    echo "  0) Свой вариант"
    read -p "Выбор (1-${#POPULAR_DOMAINS[@]}, Enter=1): " d_idx
    
    if [ -z "$d_idx" ] || [ "$d_idx" -eq 1 ]; then
        domain="${POPULAR_DOMAINS[0]}"
    elif [ "$d_idx" -eq 0 ]; then
        while true; do
            read -p "Введите домен (например: google.com): " domain
            if validate_domain "$domain"; then
                break
            else
                echo -e "${RED}[!] Неверный формат домена. Пример: google.com${NC}"
            fi
        done
    else
        domain="${POPULAR_DOMAINS[$((d_idx-1))]}"
    fi
    
    echo "$domain" > "$DOMAIN_FILE"
    echo -e "${GREEN}[+] Fake TLS: $domain${NC}"

    # Шаг 2: Публичный хост
    echo -e "\n${YELLOW}Шаг 2: Публичный адрес${NC}"
    server_ip=$(curl -s -4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    [ -z "$server_ip" ] && server_ip=$(hostname -I | awk '{print $1}')
    
    echo -e "IP сервера: ${GREEN}$server_ip${NC}"
    
    while true; do
        read -p "Публичный хост/IP [$server_ip]: " public_host
        public_host=${public_host:-$server_ip}
        
        if validate_ip_or_domain "$public_host"; then
            break
        else
            echo -e "${RED}[!] Неверный формат. Введите IP или домен${NC}"
        fi
    done
    
    echo "$public_host" > "$PUBLIC_HOST_FILE"
    echo -e "${GREEN}[+] Публичный хост: $public_host${NC}"

    # Шаг 3: Порт
    echo -e "\n${YELLOW}Шаг 3: Выбор порта${NC}"
    echo -e "${BLUE}Рекомендуемые порты: ${PREFERRED_PORTS[*]}${NC}"
    read -p "Порт (Enter для автоподбора): " user_port
    
    if [ -z "$user_port" ]; then
        port=$(find_free_port)
        if [ $? -ne 0 ]; then
            echo -e "${RED}[!] Не найден свободный порт${NC}"
            return 1
        fi
    else
        if is_port_free "$user_port"; then
            port=$user_port
        else
            echo -e "${RED}[!] Порт $user_port занят${NC}"
            port=$(find_free_port)
        fi
    fi
    
    echo "$port" > "$PORT_FILE"
    echo -e "${GREEN}[+] Выбран порт: $port${NC}"

    # Шаг 4: Пользователь
    echo -e "\n${YELLOW}Шаг 4: Настройка доступа${NC}"
    read -p "Имя пользователя (Enter=user1): " username
    username=${username:-user1}
    echo "$username" > "$USERNAME_FILE"
    
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    
    # AD TAG
    echo -e "\n${YELLOW}Шаг 5: AD TAG (опционально)${NC}"
    echo -e "${BLUE}TAG для статистики в @MTProxybot. 32 hex символа.${NC}"
    read -p "AD TAG (Enter для пропуска): " tag
    if [ -z "$tag" ]; then
        tag=""
        echo -e "${YELLOW}[!] TAG не установлен${NC}"
    elif [ ${#tag} -eq 32 ] && [[ "$tag" =~ ^[0-9a-fA-F]+$ ]]; then
        echo "$tag" > "$TAG_FILE"
        echo -e "${GREEN}[+] TAG установлен${NC}"
    else
        echo -e "${RED}[!] Неверный формат TAG, пропускаем...${NC}"
        tag=""
    fi

    generate_docker_compose "$port"
    
    if ! generate_config "$port" "$secret" "$domain" "$tag" "$public_host" "$username"; then
        echo -e "${RED}[!] Ошибка создания конфигурации${NC}"
        return 1
    fi
    
    if ! start_docker_container; then
        echo -e "${RED}[!] Ошибка запуска контейнера${NC}"
        return 1
    fi
    
    network_diagnostics "$port" "$public_host"
    
    echo -e "\n${GREEN}=== УСТАНОВКА ЗАВЕРШЕНА! ===${NC}"
    echo -e "${CYAN}📁 Директория: $DOCKER_DIR${NC}"
    echo -e "${CYAN}🔧 Управление: cd $DOCKER_DIR && $DOCKER_COMPOSE_CMD [up|down|logs|restart]${NC}"
    
    show_data
    
    read -p $'\nНажмите Enter для продолжения...'
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root

while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Telemt Proxy Manager (Docker)      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo "1) 🚀 Установить / Переустановить"
    echo "2) 📱 Показать QR, ссылку и данные"
    echo "3) 🏷️  Изменить AD TAG"
    echo "4) 📊 Статус и логи"
    echo "5) 🔄 Перезапуск контейнера"
    echo "6) 🔍 Диагностика сети"
    echo "7) 📝 Показать конфиг"
    echo "8) 🗑️  Полное удаление"
    echo "0) Выход"
    echo ""
    
    if docker ps 2>/dev/null | grep -q telemt; then
        echo -e "${GREEN}● Контейнер запущен${NC}"
    else
        echo -e "${RED}● Контейнер остановлен${NC}"
    fi
    
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_data; read -p "Enter..." ;;
        3) 
            read -p "Новый AD TAG (32 hex символа): " nt
            if [ ${#nt} -eq 32 ] && [[ "$nt" =~ ^[0-9a-fA-F]+$ ]]; then
                echo "$nt" > "$TAG_FILE"
                port=$(cat "$PORT_FILE")
                secret=$(cat "$SECRET_FILE")
                domain=$(cat "$DOMAIN_FILE")
                public_host=$(cat "$PUBLIC_HOST_FILE")
                username=$(cat "$USERNAME_FILE")
                
                generate_config "$port" "$secret" "$domain" "$nt" "$public_host" "$username"
                cd "$DOCKER_DIR" && docker_compose restart
                sleep 5
                echo -e "${GREEN}[+] AD TAG обновлен${NC}"
                show_data
            else
                echo -e "${RED}[!] Неверный формат. Нужно 32 hex символа${NC}"
            fi
            read -p "Enter..."
            ;;
        4) 
            if docker ps | grep -q telemt; then
                echo -e "\n${YELLOW}📊 Статус контейнера:${NC}"
                docker ps --filter name=telemt --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                echo -e "\n${YELLOW}📋 Последние логи (50 строк):${NC}"
                docker logs --tail=50 telemt 2>&1 | tail -50
            else
                echo -e "${RED}[!] Контейнер не запущен${NC}"
            fi
            read -p "Enter..." 
            ;;
        5) 
            if [ -f "$DOCKER_COMPOSE_FILE" ]; then
                cd "$DOCKER_DIR"
                docker_compose restart
                sleep 5
                echo -e "${GREEN}[+] Контейнер перезапущен${NC}"
            else
                echo -e "${RED}[!] Сначала установите прокси${NC}"
            fi
            read -p "Enter..."
            ;;
        6)
            if [ -f "$PORT_FILE" ] && [ -f "$PUBLIC_HOST_FILE" ]; then
                port=$(cat "$PORT_FILE")
                public_host=$(cat "$PUBLIC_HOST_FILE")
                network_diagnostics "$port" "$public_host"
            else
                echo -e "${RED}[!] Сначала установите прокси${NC}"
            fi
            read -p "Enter..."
            ;;
        7)
            show_config
            read -p "Enter..."
            ;;
        8) 
            echo -e "${RED}=== ПОЛНОЕ УДАЛЕНИЕ ===${NC}"
            read -p "Введите 'yes' для подтверждения: " confirm
            if [ "$confirm" = "yes" ]; then
                cd "$DOCKER_DIR" 2>/dev/null && docker_compose down -v 2>/dev/null
                docker rm -f telemt 2>/dev/null
                docker rmi -f whn0thacked/telemt-docker:latest 2>/dev/null
                rm -rf "$DOCKER_DIR"
                echo -e "${GREEN}[+] Telemt полностью удален${NC}"
            else
                echo -e "${YELLOW}[!] Удаление отменено${NC}"
            fi
            sleep 2
            ;;
        0) exit 0 ;;
    esac
done
