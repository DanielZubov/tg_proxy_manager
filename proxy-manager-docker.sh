#!/bin/bash

# --- КОНФИГУРАЦИЯ (Telemt Docker) ---
DOCKER_COMPOSE_DIR="/opt/telemt-docker"
CONFIG_DIR="$DOCKER_COMPOSE_DIR/config"
ENV_FILE="$DOCKER_COMPOSE_DIR/.env"
DOCKER_COMPOSE_FILE="$DOCKER_COMPOSE_DIR/docker-compose.yml"

# Файлы данных скрипта
PORT_FILE="$CONFIG_DIR/port.conf"
SECRET_FILE="$CONFIG_DIR/secret.conf"
DOMAIN_FILE="$CONFIG_DIR/domain.conf"
PUBLIC_HOST_FILE="$CONFIG_DIR/public_host.conf"
USERNAME_FILE="$CONFIG_DIR/username.conf"
TAG_FILE="$CONFIG_DIR/tag.conf"

# Приоритетные порты для автоподбора (популярные свободные порты)
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
    
    # Проверяем приоритетные порты
    for port in "${PREFERRED_PORTS[@]}"; do
        if is_port_free "$port"; then
            echo "$port"
            return 0
        fi
    done
    
    # Если все заняты, ищем в диапазоне 10000-11000
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
}

network_diagnostics() {
    local port=$1
    local public_host=$2
    
    echo -e "\n${CYAN}=== ДИАГНОСТИКА СЕТИ ===${NC}"
    
    # 1. Проверяем Docker сеть
    echo -e "\n${YELLOW}[1] Docker сеть:${NC}"
    docker network ls
    docker network inspect bridge | grep -A5 "IPAM"
    
    # 2. Проверяем, слушается ли порт
    echo -e "\n${YELLOW}[2] Прослушивание порта $port:${NC}"
    ss -tlnp | grep ":$port "
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[+] Порт слушается Docker'ом${NC}"
    else
        echo -e "${RED}[!] Порт НЕ слушается!${NC}"
    fi
    
    # 3. Проверяем файрвол
    echo -e "\n${YELLOW}[3] Проверка файрвола:${NC}"
    
    if command -v ufw >/dev/null && ufw status | grep -q "active"; then
        echo -e "${BLUE}UFW активен, добавляю правило...${NC}"
        ufw allow "$port/tcp"
        ufw allow "$port/udp"
        echo -e "${GREEN}[+] Правила добавлены${NC}"
    fi
    
    if command -v iptables >/dev/null; then
        if ! iptables -L INPUT -n | grep -q "dpt:$port"; then
            echo -e "${YELLOW}[!] Добавляю iptables правило...${NC}"
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT
        fi
    fi
    
    # 4. Проверка внешней доступности
    echo -e "\n${YELLOW}[4] Проверка доступности снаружи:${NC}"
    echo -e "${BLUE}Публичный адрес: $public_host${NC}"
    
    local ext_ip=$(curl -s -4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ ! -z "$ext_ip" ]; then
        echo -e "${BLUE}Проверка порта через онлайн-сервис...${NC}"
        local check_result=$(curl -s --connect-timeout 10 "https://portchecker.co/check?host=$ext_ip&port=$port" 2>/dev/null)
        if echo "$check_result" | grep -q '"open":true'; then
            echo -e "${GREEN}[+] Порт $port открыт снаружи${NC}"
        else
            echo -e "${YELLOW}[!] Порт $port возможно закрыт снаружи${NC}"
            echo -e "${RED}[!] ВАЖНО: Проверьте облачный файрвол!${NC}"
        fi
    fi
}

generate_docker_compose() {
    local port=$1
    local public_host=$2
    
    echo -e "${YELLOW}[*] Создание docker-compose.yml...${NC}"
    
    cat > "$DOCKER_COMPOSE_FILE" << EOF
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    
    ports:
      - "${port}:${port}"
      - "${port}:${port}/udp"
    
    command: ["/etc/telemt/telemt.toml"]
    volumes:
      - ./config:/etc/telemt
      - ./tlsfront:/opt/telemt/tlsfront
    
    environment:
      RUST_LOG: info
    
    security_opt:
      - no-new-privileges:true
    
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:9091/v1/users"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    
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
### Конфигурационный файл Telemt Proxy (Docker)

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
whitelist = ["127.0.0.0/8", "172.0.0.0/8"]

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
    
    cd "$DOCKER_COMPOSE_DIR"
    docker compose up -d --build
    
    sleep 5
    
    if docker ps | grep -q telemt; then
        echo -e "${GREEN}[+] Контейнер успешно запущен${NC}"
        
        # Проверяем логи на наличие ошибок
        if docker logs telemt 2>&1 | grep -qi "error\|panic\|fatal"; then
            echo -e "${YELLOW}[!] В логах есть ошибки, но контейнер работает${NC}"
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
    
    # Получаем ссылки из логов контейнера
    echo -e "\n${CYAN}Ссылки для подключения:${NC}"
    docker logs telemt 2>&1 | grep -E "tg://proxy" | tail -5 | while read line; do
        if [[ "$line" =~ (tg://proxy[^\ ]+) ]]; then
            link="${BASH_REMATCH[1]}"
            echo -e "${GREEN}$link${NC}"
            echo ""
            echo "$link" | qrencode -t ANSIUTF8 2>/dev/null
            echo ""
        fi
    done
    
    # Альтернативный способ через API (если доступен)
    echo -e "\n${YELLOW}[*] Альтернативные ссылки (через API):${NC}"
    docker exec telemt curl -s http://127.0.0.1:9091/v1/users 2>/dev/null | jq -r '.data[] | .links.tls[]' 2>/dev/null | while read link; do
        if [ ! -z "$link" ] && [ "$link" != "null" ]; then
            echo -e "${GREEN}$link${NC}"
        fi
    done
}

menu_install() {
    clear
    echo -e "${CYAN}=== Установка Telemt Proxy (Docker) ===${NC}"
    
    check_docker
    init_dirs

    # 1. Fake TLS домен
    echo -e "\n${YELLOW}Шаг 1: Fake TLS домен${NC}"
    echo "1) google.com"
    echo "2) cloudflare.com" 
    echo "3) microsoft.com"
    echo "4) github.com"
    echo "5) Свой вариант"
    read -p "Выбор (1-5, Enter=google.com): " d_idx
    case $d_idx in
        2) domain="cloudflare.com" ;;
        3) domain="microsoft.com" ;;
        4) domain="github.com" ;;
        5) read -p "Домен: " domain ;;
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
    
    # Проверка DNS
    if [[ "$public_host" =~ [a-zA-Z] ]] && ! [[ "$public_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${YELLOW}[*] Проверка DNS для $public_host...${NC}"
        if host "$public_host" >/dev/null 2>&1; then
            resolved_ip=$(host "$public_host" | awk '/has address/ {print $NF; exit}')
            echo -e "${GREEN}[+] $public_host резолвится в $resolved_ip${NC}"
            if [ "$resolved_ip" != "$server_ip" ]; then
                echo -e "${RED}[!] ВНИМАНИЕ: DNS указывает на $resolved_ip, а сервер имеет IP $server_ip${NC}"
                read -p "Продолжить? (y/N): " cont
                [ "$cont" != "y" ] && return
            fi
        else
            echo -e "${RED}[!] Домен $public_host не резолвится${NC}"
            read -p "Использовать IP? (Y/n): " use_ip
            [ "$use_ip" != "n" ] && public_host="$server_ip"
        fi
    fi
    
    echo "$public_host" > "$PUBLIC_HOST_FILE"
    echo -e "${GREEN}[+] Публичный хост: $public_host${NC}"

    # 3. Порт (автоподбор)
    echo -e "\n${YELLOW}Шаг 3: Выбор порта${NC}"
    echo -e "${BLUE}Рекомендуемые порты: ${PREFERRED_PORTS[*]}${NC}"
    read -p "Порт (Enter для автоподбора, или укажите свой): " user_port
    
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

    # 4. Имя пользователя и секреты
    echo -e "\n${YELLOW}Шаг 4: Настройка доступа${NC}"
    read -p "Имя пользователя (Enter=user1): " username
    username=${username:-user1}
    echo "$username" > "$USERNAME_FILE"
    
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    
    # Генерация случайного TAG (32 hex символа)
    tag=$(openssl rand -hex 16)
    echo "$tag" > "$TAG_FILE"
    
    echo -e "${GREEN}[+] Пользователь: $username${NC}"
    echo -e "${GREEN}[+] Secret: ${secret:0:16}...${NC}"
    echo -e "${GREEN}[+] TAG: ${tag:0:16}...${NC}"

    # Установка
    echo -e "\n${CYAN}=== Установка ===${NC}"
    
    generate_docker_compose "$free_port" "$public_host"
    
    if ! generate_config "$free_port" "$secret" "$domain" "$tag" "$public_host" "$username"; then
        echo -e "${RED}[!] Ошибка создания конфигурации${NC}"
        return 1
    fi
    
    if ! start_docker_container; then
        echo -e "${RED}[!] Ошибка запуска контейнера${NC}"
        return 1
    fi
    
    # Диагностика сети
    network_diagnostics "$free_port" "$public_host"
    
    echo -e "\n${GREEN}=== Установка завершена! ===${NC}"
    echo -e "${CYAN}Директория: $DOCKER_COMPOSE_DIR${NC}"
    echo -e "${CYAN}Для управления: cd $DOCKER_COMPOSE_DIR && docker compose [up|down|logs|restart]${NC}"
    
    show_data
    read -p "Нажмите Enter..."
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root

while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Telemt Proxy Manager (Docker) v1.0   ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo "1) 🚀 Установить / Переустановить"
    echo "2) 📱 Показать QR и ссылки"
    echo "3) 🏷️  Изменить AD TAG"
    echo "4) 📊 Статус и логи"
    echo "5) 🔄 Перезапуск контейнера"
    echo "6) 🔍 ДИАГНОСТИКА СЕТИ"
    echo "7) 📝 Показать конфиг"
    echo "8) 🗑️  Полное удаление"
    echo "0) Выход"
    echo ""
    
    if docker ps | grep -q telemt 2>/dev/null; then
        echo -e "${GREEN}● Контейнер запущен${NC}"
    else
        echo -e "${RED}● Контейнер остановлен${NC}"
    fi
    
    read -p "Выбор: " idx
    case $idx in
        1) menu_install ;;
        2) show_data; read -p "Enter..." ;;
        3) 
            read -p "Новый TAG (32 hex символа): " nt
            if [ ${#nt} -eq 32 ] && [[ "$nt" =~ ^[0-9a-fA-F]+$ ]]; then
                echo "$nt" > "$TAG_FILE"
                # Пересоздаем конфиг и перезапускаем
                port=$(cat "$PORT_FILE")
                secret=$(cat "$SECRET_FILE")
                domain=$(cat "$DOMAIN_FILE")
                public_host=$(cat "$PUBLIC_HOST_FILE")
                username=$(cat "$USERNAME_FILE")
                
                generate_config "$port" "$secret" "$domain" "$nt" "$public_host" "$username"
                cd "$DOCKER_COMPOSE_DIR"
                docker compose restart
                echo -e "${GREEN}[+] TAG обновлен, контейнер перезапущен${NC}"
            else
                echo -e "${RED}[!] Неверный формат TAG (нужно 32 hex символа)${NC}"
            fi
            sleep 2
            ;;
        4) 
            if docker ps | grep -q telemt; then
                echo -e "\n${YELLOW}Статус контейнера:${NC}"
                docker ps --filter name=telemt
                echo -e "\n${YELLOW}Последние логи:${NC}"
                docker logs --tail=50 telemt
            else
                echo -e "${RED}[!] Контейнер не запущен${NC}"
            fi
            read -p "Enter..." 
            ;;
        5) 
            if [ -f "$DOCKER_COMPOSE_FILE" ]; then
                cd "$DOCKER_COMPOSE_DIR"
                docker compose restart
                sleep 3
                docker ps | grep -q telemt && \
                    echo -e "${GREEN}[+] Контейнер перезапущен${NC}" || \
                    echo -e "${RED}[!] Ошибка перезапуска${NC}"
            else
                echo -e "${RED}[!] Сначала установите прокси${NC}"
            fi
            sleep 1
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
            if [ -f "$CONFIG_DIR/telemt.toml" ]; then
                cat "$CONFIG_DIR/telemt.toml"
            else
                echo -e "${RED}[!] Конфиг не найден${NC}"
            fi
            read -p "Enter..."
            ;;
        8) 
            echo -e "${RED}=== ПОЛНОЕ УДАЛЕНИЕ TELEMT ===${NC}"
            echo -e "${YELLOW}Будут удалены:${NC}"
            echo "  - Docker контейнер telemt"
            echo "  - Docker образ"
            echo "  - Все конфигурационные файлы"
            echo "  - Директория $DOCKER_COMPOSE_DIR"
            echo ""
            read -p "Введите 'yes' для подтверждения: " confirm
            if [ "$confirm" = "yes" ]; then
                cd "$DOCKER_COMPOSE_DIR" 2>/dev/null
                docker compose down -v 2>/dev/null
                docker rm -f telemt 2>/dev/null
                docker rmi -f whn0thacked/telemt-docker:latest 2>/dev/null
                rm -rf "$DOCKER_COMPOSE_DIR"
                echo -e "${GREEN}[+] Telemt полностью удален${NC}"
            else
                echo -e "${YELLOW}[!] Удаление отменено${NC}"
            fi
            sleep 2
            ;;
        0) exit 0 ;;
    esac
done
