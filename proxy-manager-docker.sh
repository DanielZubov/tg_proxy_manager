#!/bin/bash

# --- КОНФИГУРАЦИЯ (Telemt Docker) ---
DOCKER_COMPOSE_DIR="/opt/telemt-docker"
CONFIG_DIR="$DOCKER_COMPOSE_DIR/config"
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_DIR/docker-compose.yml"

# Файлы данных скрипта
PORT_FILE="$CONFIG_DIR/port.conf"
SECRET_FILE="$CONFIG_DIR/secret.conf"
DOMAIN_FILE="$CONFIG_DIR/domain.conf"
PUBLIC_HOST_FILE="$CONFIG_DIR/public_host.conf"
USERNAME_FILE="$CONFIG_DIR/username.conf"
TAG_FILE="$CONFIG_DIR/tag.conf"

# Приоритетные порты
PREFERRED_PORTS=(9444 8444 9443 8443 8080 8880 4343 4443 7443 6443)

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

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] Установка Docker...${NC}"
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        echo -e "${GREEN}[+] Docker установлен${NC}"
    fi
    
    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] Установка Docker Compose...${NC}"
        apt-get update -qq
        apt-get install -y -qq docker-compose
        echo -e "${GREEN}[+] Docker Compose установлен${NC}"
    fi
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

init_dirs() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$DOCKER_COMPOSE_DIR/tlsfront"
    chmod 755 "$CONFIG_DIR"
    chmod 777 "$DOCKER_COMPOSE_DIR/tlsfront"
}

# Скачиваем proxy-secret напрямую (обход блокировки через разные зеркала)
download_proxy_secret() {
    echo -e "${YELLOW}[*] Загрузка proxy-secret...${NC}"
    
    local urls=(
        "https://raw.githubusercontent.com/TelegramMessenger/MTProxy/master/proxy-secret"
        "https://core.telegram.org/getProxySecret"
        "https://telegram.org/proxy-secret"
        "https://td.telegram.org/tl/tscheme"
    )
    
    for url in "${urls[@]}"; do
        echo -e "${BLUE}Пробуем $url...${NC}"
        if curl -sSL --connect-timeout 10 "$url" -o "$CONFIG_DIR/proxy-secret" 2>/dev/null; then
            if [ -s "$CONFIG_DIR/proxy-secret" ]; then
                echo -e "${GREEN}[+] proxy-secret загружен${NC}"
                chmod 644 "$CONFIG_DIR/proxy-secret"
                return 0
            fi
        fi
    done
    
    # Если не удалось скачать, используем встроенный
    echo -e "${YELLOW}[!] Использую встроенный proxy-secret${NC}"
    cat > "$CONFIG_DIR/proxy-secret" << 'EOF'
eea2b5ad45493e8a1d4b5e7f5c8a9b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9
EOF
    return 0
}

generate_docker_compose() {
    local port=$1
    
    echo -e "${YELLOW}[*] Создание docker-compose.yml...${NC}"
    
    cat > "$DOCKER_COMPOSE_FILE" << EOF
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    
    network_mode: host
    # Используем host network для лучшей совместимости
    
    command: ["/etc/telemt/telemt.toml"]
    volumes:
      - ./config:/etc/telemt
      - ./tlsfront:/opt/telemt/tlsfront
    
    environment:
      RUST_LOG: info
      RUST_BACKTRACE: 1
    
    security_opt:
      - no-new-privileges:true
    
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - NET_ADMIN
      - NET_RAW
    
    read_only: false
    
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
    
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
    
    cat > "$CONFIG_DIR/telemt.toml" << EOF
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
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.0/8", "172.0.0.0/8", "192.168.0.0/16"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "$domain"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
$username = "$secret"

[proxy_secret]
proxy_secret = "/etc/telemt/proxy-secret"
EOF
    
    if [ $? -eq 0 ]; then
        chmod 644 "$CONFIG_DIR/telemt.toml"
        echo -e "${GREEN}[+] Конфигурация создана${NC}"
        return 0
    else
        echo -e "${RED}[!] Ошибка создания конфига${NC}"
        return 1
    fi
}

start_docker_container() {
    echo -e "${YELLOW}[*] Запуск Docker контейнера...${NC}"
    
    cd "$DOCKER_COMPOSE_DIR"
    docker compose down 2>/dev/null
    docker compose up -d
    
    echo -e "${YELLOW}[*] Ожидание запуска (20 секунд)...${NC}"
    sleep 20
    
    if docker ps | grep -q telemt; then
        echo -e "${GREEN}[+] Контейнер успешно запущен${NC}"
        
        # Проверяем режим работы
        sleep 5
        if docker logs telemt 2>&1 | grep -q "Middle Proxy Mode"; then
            echo -e "${GREEN}[+] Прокси работает в Middle Proxy Mode${NC}"
        else
            echo -e "${YELLOW}[!] Прокси работает в Direct Mode${NC}"
        fi
        return 0
    else
        echo -e "${RED}[!] Ошибка запуска контейнера${NC}"
        docker compose logs --tail=30
        return 1
    fi
}

show_data() {
    if ! docker ps | grep -q telemt; then
        echo -e "${RED}[!] Контейнер не запущен${NC}"
        return
    fi
    
    echo -e "\n${GREEN}=== Данные для подключения ===${NC}"
    
    # Получаем ссылки из логов
    echo -e "\n${CYAN}📱 Ссылки для подключения:${NC}"
    
    # Ждем появления ссылок
    for i in {1..15}; do
        sleep 1
        LINKS=$(docker logs telemt 2>&1 | grep -oE 'tg://proxy[^[:space:]]+' | grep -v "secret=" | head -1)
        if [ ! -z "$LINKS" ]; then
            break
        fi
    done
    
    if [ ! -z "$LINKS" ]; then
        echo -e "${GREEN}$LINKS${NC}"
        echo ""
        echo -e "${YELLOW}📱 QR Code:${NC}"
        echo "$LINKS" | qrencode -t ANSIUTF8 2>/dev/null
        echo ""
        
        # Альтернативные ссылки
        echo -e "${CYAN}📋 Альтернативные ссылки:${NC}"
        docker logs telemt 2>&1 | grep -oE 'tg://proxy[^[:space:]]+' | while read link; do
            if [ "$link" != "$LINKS" ]; then
                echo -e "${GREEN}$link${NC}"
            fi
        done
    else
        echo -e "${YELLOW}[!] Ссылки не найдены. Проверьте логи:${NC}"
        echo -e "${BLUE}docker logs telemt --tail=30${NC}"
        
        # Показываем последние логи
        echo -e "\n${YELLOW}Последние логи:${NC}"
        docker logs telemt --tail=20 2>&1 | grep -E "Listening|Proxy Links|tg://|Mode"
    fi
}

menu_install() {
    clear
    echo -e "${CYAN}=== Установка Telemt Proxy (Docker) ===${NC}"
    
    check_docker
    init_dirs

    # Останавливаем старый контейнер
    cd "$DOCKER_COMPOSE_DIR" 2>/dev/null && docker compose down 2>/dev/null

    # 1. Fake TLS домен
    echo -e "\n${YELLOW}Шаг 1: Fake TLS домен${NC}"
    echo "1) google.com"
    echo "2) cloudflare.com" 
    echo "3) microsoft.com"
    echo "4) github.com"
    echo "5) apple.com"
    echo "6) Свой вариант"
    read -p "Выбор (1-6, Enter=google.com): " d_idx
    case $d_idx in
        2) domain="cloudflare.com" ;;
        3) domain="microsoft.com" ;;
        4) domain="github.com" ;;
        5) domain="apple.com" ;;
        6) read -p "Домен: " domain ;;
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
    
    echo "$public_host" > "$PUBLIC_HOST_FILE"
    echo -e "${GREEN}[+] Публичный хост: $public_host${NC}"

    # 3. Порт
    echo -e "\n${YELLOW}Шаг 3: Выбор порта${NC}"
    echo -e "${BLUE}Рекомендуемые порты: ${PREFERRED_PORTS[*]}${NC}"
    read -p "Порт (Enter для автоподбора): " user_port
    
    if [ -z "$user_port" ]; then
        free_port=$(find_free_port)
        if [ $? -ne 0 ]; then
            echo -e "${RED}[!] Не найден свободный порт${NC}"
            return 1
        fi
    else
        if is_port_free "$user_port"; then
            free_port=$user_port
        else
            echo -e "${RED}[!] Порт $user_port занят${NC}"
            free_port=$(find_free_port)
        fi
    fi
    
    echo "$free_port" > "$PORT_FILE"
    echo -e "${GREEN}[+] Выбран порт: $free_port${NC}"

    # 4. Секреты
    echo -e "\n${YELLOW}Шаг 4: Настройка доступа${NC}"
    read -p "Имя пользователя (Enter=user1): " username
    username=${username:-user1}
    echo "$username" > "$USERNAME_FILE"
    
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    
    tag=$(openssl rand -hex 16)
    echo "$tag" > "$TAG_FILE"
    
    echo -e "${GREEN}[+] Пользователь: $username${NC}"
    echo -e "${GREEN}[+] Secret: ${secret}${NC}"
    echo -e "${GREEN}[+] TAG: ${tag}${NC}"

    # 5. Загрузка proxy-secret
    download_proxy_secret

    # Установка
    echo -e "\n${CYAN}=== Установка ===${NC}"
    
    generate_docker_compose "$free_port"
    
    if ! generate_config "$free_port" "$secret" "$domain" "$tag" "$public_host" "$username"; then
        echo -e "${RED}[!] Ошибка создания конфигурации${NC}"
        return 1
    fi
    
    if ! start_docker_container; then
        echo -e "${RED}[!] Ошибка запуска контейнера${NC}"
        return 1
    fi
    
    echo -e "\n${GREEN}=== УСТАНОВКА ЗАВЕРШЕНА! ===${NC}"
    echo -e "${CYAN}📁 Директория: $DOCKER_COMPOSE_DIR${NC}"
    echo -e "${CYAN}🔧 Управление: cd $DOCKER_COMPOSE_DIR && docker compose [up|down|logs|restart]${NC}"
    
    # Показываем ссылки
    show_data
    
    # Проверяем файрвол
    echo -e "\n${YELLOW}📌 Не забудьте открыть порт $free_port в файрволе:${NC}"
    echo -e "  ${BLUE}ufw allow $free_port${NC}"
    echo -e "  ${BLUE}iptables -I INPUT -p tcp --dport $free_port -j ACCEPT${NC}"
    
    read -p $'\nНажмите Enter для продолжения...'
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root

while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Telemt Proxy Manager (Docker) v1.2   ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo "1) 🚀 Установить / Переустановить"
    echo "2) 📱 Показать QR и ссылки"
    echo "3) 🏷️  Изменить AD TAG"
    echo "4) 📊 Статус и логи"
    echo "5) 🔄 Перезапуск контейнера"
    echo "6) 🔍 ДИАГНОСТИКА"
    echo "7) 📝 Показать конфиг"
    echo "8) 🗑️  Полное удаление"
    echo "0) Выход"
    echo ""
    
    if docker ps | grep -q telemt 2>/dev/null; then
        MODE=$(docker logs telemt 2>&1 | grep -q "Middle Proxy Mode" && echo "Middle Proxy" || echo "Direct Mode")
        echo -e "${GREEN}● Контейнер запущен (${MODE})${NC}"
    else
        echo -e "${RED}● Контейнер остановлен${NC}"
    fi
    
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_data; read -p "Enter..." ;;
        3) 
            read -p "Новый TAG (32 hex): " nt
            if [ ${#nt} -eq 32 ] && [[ "$nt" =~ ^[0-9a-fA-F]+$ ]]; then
                echo "$nt" > "$TAG_FILE"
                port=$(cat "$PORT_FILE")
                secret=$(cat "$SECRET_FILE")
                domain=$(cat "$DOMAIN_FILE")
                public_host=$(cat "$PUBLIC_HOST_FILE")
                username=$(cat "$USERNAME_FILE")
                
                generate_config "$port" "$secret" "$domain" "$nt" "$public_host" "$username"
                cd "$DOCKER_COMPOSE_DIR" && docker compose restart
                sleep 5
                echo -e "${GREEN}[+] TAG обновлен${NC}"
                show_data
            else
                echo -e "${RED}[!] Нужно 32 hex символа${NC}"
            fi
            read -p "Enter..."
            ;;
        4) 
            if docker ps | grep -q telemt; then
                echo -e "\n${YELLOW}📊 Статус:${NC}"
                docker ps --filter name=telemt --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                echo -e "\n${YELLOW}📋 Логи (30 строк):${NC}"
                docker logs --tail=30 telemt 2>&1 | tail -30
            else
                echo -e "${RED}[!] Контейнер не запущен${NC}"
            fi
            read -p "Enter..." 
            ;;
        5) 
            cd "$DOCKER_COMPOSE_DIR" 2>/dev/null && docker compose restart && sleep 5 && show_data
            read -p "Enter..."
            ;;
        6)
            echo -e "\n${YELLOW}🔍 Диагностика:${NC}"
            if docker ps | grep -q telemt; then
                echo -e "${GREEN}[+] Контейнер запущен${NC}"
                docker logs telemt 2>&1 | grep -E "Mode|Listening|Error|WARN" | tail -10
            else
                echo -e "${RED}[!] Контейнер не запущен${NC}"
            fi
            read -p "Enter..."
            ;;
        7)
            if [ -f "$CONFIG_DIR/telemt.toml" ]; then
                cat "$CONFIG_DIR/telemt.toml"
            else
                echo -e "${RED}[!] Конфиг не найден${NC}"
            fi
            read -p "Enter..."
            ;;
        8) 
            echo -e "${RED}=== ПОЛНОЕ УДАЛЕНИЕ ===${NC}"
            read -p "Введите 'yes' для подтверждения: " confirm
            if [ "$confirm" = "yes" ]; then
                cd "$DOCKER_COMPOSE_DIR" 2>/dev/null && docker compose down -v 2>/dev/null
                docker rm -f telemt 2>/dev/null
                docker rmi -f whn0thacked/telemt-docker:latest 2>/dev/null
                rm -rf "$DOCKER_COMPOSE_DIR"
                echo -e "${GREEN}[+] Удалено${NC}"
            fi
            sleep 2
            ;;
        0) exit 0 ;;
    esac
done
