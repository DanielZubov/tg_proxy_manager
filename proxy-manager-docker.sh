#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
DOCKER_DIR="/opt/telemt"
CONFIG_FILE="$DOCKER_DIR/config.toml"
PORT_FILE="$DOCKER_DIR/port.conf"
SECRET_FILE="$DOCKER_DIR/secret.conf"
DOMAIN_FILE="$DOCKER_DIR/domain.conf"
PUBLIC_HOST_FILE="$DOCKER_DIR/public_host.conf"
USERNAME_FILE="$DOCKER_DIR/username.conf"

# Приоритетные порты
PREFERRED_PORTS=(9444 8444 9443 8443 8080 8880)

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Ошибка: запустите от root!${NC}"
        exit 1
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
    for port in $(seq 10000 10100); do
        if is_port_free "$port"; then
            echo "$port"
            return 0
        fi
    done
    echo -e "${RED}[!] Не найден свободный порт!${NC}" >&2
    return 1
}

generate_config() {
    local port=$1
    local secret=$2
    local domain=$3
    local public_host=$4
    local username=$5
    
    cat > "$CONFIG_FILE" << EOF
### Telemt Based Config.toml

[general]
use_middle_proxy = true
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
    
    echo -e "${GREEN}[+] Конфиг создан: $CONFIG_FILE${NC}"
}

create_docker_compose() {
    local port=$1
    
    cat > "$DOCKER_DIR/docker-compose.yml" << EOF
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
    echo -e "${GREEN}[+] docker-compose.yml создан${NC}"
}

show_qr() {
    local link=$1
    echo -e "\n${YELLOW}📱 QR Code:${NC}"
    echo "$link" | qrencode -t ANSIUTF8 2>/dev/null
    echo ""
}

menu_install() {
    clear
    echo -e "${CYAN}=== Установка Telemt Proxy (Docker) ===${NC}"
    
    # Установка Docker если нужно
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] Установка Docker...${NC}"
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
    fi
    
    # Создаем директорию
    mkdir -p "$DOCKER_DIR"
    cd "$DOCKER_DIR"
    
    # Останавливаем старый контейнер если есть
    docker compose down 2>/dev/null
    
    # 1. Fake TLS домен
    echo -e "\n${YELLOW}Шаг 1: Fake TLS домен${NC}"
    echo "1) google.com"
    echo "2) cloudflare.com" 
    echo "3) microsoft.com"
    echo "4) github.com"
    echo "5) apple.com"
    read -p "Выбор (1-5, Enter=google.com): " d_idx
    case $d_idx in
        2) domain="cloudflare.com" ;;
        3) domain="microsoft.com" ;;
        4) domain="github.com" ;;
        5) domain="apple.com" ;;
        *) domain="google.com" ;;
    esac
    echo "$domain" > "$DOMAIN_FILE"
    echo -e "${GREEN}[+] Fake TLS: $domain${NC}"
    
    # 2. Публичный хост (внешний IP)
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
    read -p "Порт (Enter для автоподбора): " user_port
    
    if [ -z "$user_port" ]; then
        port=$(find_free_port)
    else
        if is_port_free "$user_port"; then
            port=$user_port
        else
            echo -e "${RED}[!] Порт $user_port занят${NC}"
            port=$(find_free_port)
        fi
    fi
    echo "$port" > "$PORT_FILE"
    echo -e "${GREEN}[+] Порт: $port${NC}"
    
    # 4. Пользователь и секрет
    echo -e "\n${YELLOW}Шаг 4: Настройка доступа${NC}"
    read -p "Имя пользователя (Enter=user1): " username
    username=${username:-user1}
    echo "$username" > "$USERNAME_FILE"
    
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    echo -e "${GREEN}[+] Пользователь: $username${NC}"
    echo -e "${GREEN}[+] Secret: $secret${NC}"
    
    # Создаем файлы
    generate_config "$port" "$secret" "$domain" "$public_host" "$username"
    create_docker_compose "$port"
    
    # Запускаем
    echo -e "\n${YELLOW}[*] Запуск контейнера...${NC}"
    docker compose up -d
    
    sleep 5
    
    # Показываем ссылку
    echo -e "\n${GREEN}=== ГОТОВО! ===${NC}"
    
    # Получаем ссылку из логов
    LINK=$(docker logs telemt 2>&1 | grep -oE 'tg://proxy[^[:space:]]+' | head -1)
    
    if [ ! -z "$LINK" ]; then
        echo -e "\n${CYAN}📱 Ссылка для подключения:${NC}"
        echo -e "${GREEN}$LINK${NC}"
        show_qr "$LINK"
    else
        echo -e "${YELLOW}[!] Ждем инициализацию...${NC}"
        sleep 10
        LINK=$(docker logs telemt 2>&1 | grep -oE 'tg://proxy[^[:space:]]+' | head -1)
        if [ ! -z "$LINK" ]; then
            echo -e "${GREEN}$LINK${NC}"
            show_qr "$LINK"
        fi
    fi
    
    echo -e "\n${CYAN}📁 Директория: $DOCKER_DIR${NC}"
    echo -e "${CYAN}🔧 Управление: cd $DOCKER_DIR && docker compose [up|down|logs|restart]${NC}"
    echo -e "${YELLOW}📌 Не забудьте открыть порт $port в файрволе!${NC}"
    
    read -p $'\nНажмите Enter...'
}

show_data() {
    cd "$DOCKER_DIR" 2>/dev/null || { echo -e "${RED}Прокси не установлен${NC}"; return; }
    
    if ! docker ps | grep -q telemt; then
        echo -e "${RED}[!] Контейнер не запущен${NC}"
        return
    fi
    
    LINK=$(docker logs telemt 2>&1 | grep -oE 'tg://proxy[^[:space:]]+' | head -1)
    
    if [ ! -z "$LINK" ]; then
        echo -e "\n${CYAN}📱 Ссылка для подключения:${NC}"
        echo -e "${GREEN}$LINK${NC}"
        show_qr "$LINK"
    else
        echo -e "${YELLOW}[!] Ссылка не найдена. Проверьте логи: docker logs telemt${NC}"
    fi
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root

while true; do
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Telemt Proxy (Docker) v1.0        ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo "1) 🚀 Установить"
    echo "2) 📱 Показать QR и ссылку"
    echo "3) 📊 Логи"
    echo "4) 🔄 Перезапуск"
    echo "5) 🗑️  Удалить"
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
            if docker ps | grep -q telemt; then
                docker logs --tail=50 telemt
            else
                echo -e "${RED}Контейнер не запущен${NC}"
            fi
            read -p "Enter..." 
            ;;
        4) 
            cd "$DOCKER_DIR" 2>/dev/null && docker compose restart
            sleep 3
            echo -e "${GREEN}Перезапущено${NC}"
            sleep 1
            ;;
        5) 
            echo -e "${RED}Удалить Telemt?${NC}"
            read -p "Введите 'yes': " confirm
            if [ "$confirm" = "yes" ]; then
                cd "$DOCKER_DIR" 2>/dev/null && docker compose down -v 2>/dev/null
                docker rm -f telemt 2>/dev/null
                rm -rf "$DOCKER_DIR"
                echo -e "${GREEN}Удалено${NC}"
            fi
            sleep 2
            ;;
        0) exit 0 ;;
    esac
done
