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

# Популярные домены (международные + РФ)
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
    # Проверка на IP
    if [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    # Проверка на домен
    if [[ "$input" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# Новая функция: проверка что домен резолвится в IP сервера
validate_public_host() {
    local public_host=$1
    local server_ip=$2
    
    # Если публичный хост - это IP адрес
    if [[ "$public_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [ "$public_host" != "$server_ip" ]; then
            echo -e "${RED}[!] ВНИМАНИЕ: Вы указали IP $public_host, но IP сервера $server_ip${NC}"
            echo -e "${YELLOW}Убедитесь, что клиенты будут использовать правильный адрес!${NC}"
            read -p "Продолжить? (y/N): " cont
            [ "$cont" != "y" ] && return 1
        fi
        return 0
    fi
    
    # Если публичный хост - это домен
    echo -e "${BLUE}[*] Проверка DNS для $public_host...${NC}"
    
    # Пробуем разные DNS сервера для резолвинга
    local resolved_ip=""
    for dns in "8.8.8.8" "1.1.1.1" "77.88.8.8" "8.8.4.4"; do
        resolved_ip=$(dig +short @$dns "$public_host" A 2>/dev/null | head -1)
        if [ ! -z "$resolved_ip" ]; then
            break
        fi
    done
    
    # Если dig не сработал, пробуем host
    if [ -z "$resolved_ip" ]; then
        resolved_ip=$(host "$public_host" 2>/dev/null | awk '/has address/ {print $NF; exit}')
    fi
    
    # Если все еще пусто, пробуем nslookup
    if [ -z "$resolved_ip" ]; then
        resolved_ip=$(nslookup "$public_host" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1)
    fi
    
    if [ -z "$resolved_ip" ]; then
        echo -e "${RED}[!] Домен $public_host не резолвится!${NC}"
        echo -e "${YELLOW}Возможные причины:${NC}"
        echo -e "  - Домен не зарегистрирован или не настроен"
        echo -e "  - DNS записи еще не распространились"
        echo -e "  - Указан неверный домен"
        echo ""
        read -p "Использовать IP адрес $server_ip вместо домена? (Y/n): " use_ip
        if [ "$use_ip" != "n" ]; then
            public_host="$server_ip"
            echo -e "${GREEN}[+] Будет использован IP: $public_host${NC}"
        else
            echo -e "${RED}[!] Прокси может не работать, так как домен не резолвится${NC}"
            read -p "Продолжить с доменом? (y/N): " cont
            [ "$cont" != "y" ] && return 1
        fi
        return 0
    fi
    
    echo -e "${GREEN}[+] $public_host резолвится в $resolved_ip${NC}"
    
    if [ "$resolved_ip" != "$server_ip" ]; then
        echo -e "${RED}[!] ВНИМАНИЕ: Домен указывает на $resolved_ip, но сервер имеет IP $server_ip${NC}"
        echo -e "${YELLOW}Клиенты не смогут подключиться, если DNS не настроен правильно!${NC}"
        echo ""
        echo -e "${BLUE}Что делать:${NC}"
        echo -e "  1. Создайте A запись для $public_host → $server_ip"
        echo -e "  2. Дождитесь распространения DNS (может занять до 24 часов)"
        echo -e "  3. Или используйте IP адрес вместо домена"
        echo ""
        read -p "Использовать IP адрес $server_ip? (Y/n): " use_ip
        if [ "$use_ip" != "n" ]; then
            public_host="$server_ip"
            echo -e "${GREEN}[+] Будет использован IP: $public_host${NC}"
        else
            echo -e "${YELLOW}[!] Продолжаем с доменом, но проверьте DNS настройки!${NC}"
            read -p "Нажмите Enter чтобы продолжить..."
        fi
    else
        echo -e "${GREEN}[+] Отлично! Домен правильно указывает на ваш сервер${NC}"
    fi
    
    eval "$2='$public_host'"
    return 0
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
    
    echo -e "\n${YELLOW}[4] Проверка доступности снаружи:${NC}"
    local ext_ip=$(curl -s -4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ ! -z "$ext_ip" ]; then
        echo -e "${BLUE}Внешний IP: $ext_ip${NC}"
        echo -e "${YELLOW}Проверить порт можно на: https://portchecker.co/check?host=$ext_ip&port=$port${NC}"
    fi
    
    echo -e "\n${YELLOW}[5] Статус контейнера:${NC}"
    docker ps --filter name=telemt --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
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
    docker compose down 2>/dev/null
    docker compose up -d
    
    echo -e "${YELLOW}[*] Ожидание запуска (10 секунд)...${NC}"
    sleep 10
    
    if docker ps | grep -q telemt; then
        echo -e "${GREEN}[+] Контейнер успешно запущен${NC}"
        return 0
    else
        echo -e "${RED}[!] Ошибка запуска контейнера${NC}"
        docker compose logs --tail=30
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
    
    # Получаем ссылку из логов
    LINK=$(docker logs telemt 2>&1 | grep -oE 'tg://proxy[^[:space:]]+' | head -1)
    
    if [ ! -z "$LINK" ]; then
        echo -e "\n${CYAN}📱 Ссылка для Telegram:${NC}"
        echo -e "${GREEN}$LINK${NC}"
        show_qr "$LINK"
        
        # Данные для ручной настройки
        echo -e "\n${CYAN}📋 Данные для ручной настройки:${NC}"
        if [ -f "$PUBLIC_HOST_FILE" ] && [ -f "$PORT_FILE" ] && [ -f "$SECRET_FILE" ]; then
            HOST=$(cat "$PUBLIC_HOST_FILE")
            PORT=$(cat "$PORT_FILE")
            SECRET=$(cat "$SECRET_FILE")
            echo -e "  ${BLUE}HOST:${NC} $HOST"
            echo -e "  ${BLUE}PORT:${NC} $PORT"
            echo -e "  ${BLUE}SECRET:${NC} $SECRET"
        fi
        
        # Данные для промо канала
        echo -e "\n${CYAN}📢 Для настройки промо канала (MTProto формата):${NC}"
        echo -e "  ${BLUE}HOST:PORT${NC} $HOST:$PORT"
        echo -e "  ${BLUE}Secret:${NC} $SECRET"
        
    else
        echo -e "${YELLOW}[!] Ссылка еще не сгенерирована, попробуйте позже${NC}"
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
    
    # Создаем директорию
    mkdir -p "$DOCKER_DIR"
    cd "$DOCKER_DIR"
    
    # Останавливаем старый контейнер если есть
    docker compose down 2>/dev/null

    # 1. Fake TLS домен
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

    # 2. Публичный хост (с проверкой DNS)
    echo -e "\n${YELLOW}Шаг 2: Публичный адрес${NC}"
    server_ip=$(curl -s -4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ -z "$server_ip" ] || [ "$server_ip" = "null" ]; then
        server_ip=$(hostname -I | awk '{print $1}')
    fi
    
    echo -e "IP сервера: ${GREEN}$server_ip${NC}"
    
    while true; do
        read -p "Публичный хост/IP [$server_ip]: " public_host
        public_host=${public_host:-$server_ip}
        
        # Валидация формата
        if ! validate_ip_or_domain "$public_host"; then
            echo -e "${RED}[!] Неверный формат. Введите IP или домен (например: example.com)${NC}"
            continue
        fi
        
        # Проверка DNS резолвинга для доменов
        if [[ "$public_host" =~ [a-zA-Z] ]] && ! [[ "$public_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # Это домен, проверяем резолвинг
            local resolved_ip=""
            for dns in "8.8.8.8" "1.1.1.1" "77.88.8.8"; do
                resolved_ip=$(dig +short @$dns "$public_host" A 2>/dev/null | head -1)
                [ ! -z "$resolved_ip" ] && break
            done
            
            if [ -z "$resolved_ip" ]; then
                echo -e "${RED}[!] Домен $public_host не резолвится!${NC}"
                echo -e "${YELLOW}Проверьте DNS записи или используйте IP адрес${NC}"
                echo ""
                read -p "Использовать IP $server_ip? (Y/n): " use_ip
                if [ "$use_ip" != "n" ]; then
                    public_host="$server_ip"
                    echo -e "${GREEN}[+] Будет использован IP: $public_host${NC}"
                    break
                else
                    continue
                fi
            fi
            
            echo -e "${GREEN}[+] DNS: $public_host → $resolved_ip${NC}"
            
            if [ "$resolved_ip" != "$server_ip" ]; then
                echo -e "${RED}[!] ВНИМАНИЕ: Домен указывает на $resolved_ip, но сервер имеет IP $server_ip${NC}"
                echo -e "${YELLOW}Клиенты не смогут подключиться!${NC}"
                echo ""
                echo -e "${BLUE}Рекомендации:${NC}"
                echo -e "  1. Создайте A запись: $public_host → $server_ip"
                echo -e "  2. Или используйте IP адрес вместо домена"
                echo ""
                read -p "Использовать IP $server_ip? (Y/n): " use_ip
                if [ "$use_ip" != "n" ]; then
                    public_host="$server_ip"
                    echo -e "${GREEN}[+] Будет использован IP: $public_host${NC}"
                else
                    echo -e "${YELLOW}[!] Продолжаем с доменом, но убедитесь что DNS настроен правильно!${NC}"
                    read -p "Нажмите Enter чтобы продолжить..."
                fi
            else
                echo -e "${GREEN}[+] Отлично! Домен правильно указывает на ваш сервер${NC}"
            fi
        elif [[ "$public_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # Это IP адрес
            if [ "$public_host" != "$server_ip" ]; then
                echo -e "${YELLOW}[!] Вы указали IP $public_host, но реальный IP сервера $server_ip${NC}"
                echo -e "${YELLOW}Убедитесь, что это правильный публичный IP${NC}"
                read -p "Продолжить? (y/N): " cont
                if [ "$cont" != "y" ]; then
                    continue
                fi
            fi
        fi
        break
    done
    
    echo "$public_host" > "$PUBLIC_HOST_FILE"
    echo -e "${GREEN}[+] Публичный хост: $public_host${NC}"

    # 3. Порт
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

    # 4. Пользователь и секреты
    echo -e "\n${YELLOW}Шаг 4: Настройка доступа${NC}"
    read -p "Имя пользователя (Enter=user1): " username
    username=${username:-user1}
    echo "$username" > "$USERNAME_FILE"
    
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    
    # AD TAG
    echo -e "\n${YELLOW}Шаг 5: AD TAG (опционально)${NC}"
    echo -e "${BLUE}TAG используется для статистики в @MTProxybot. Оставьте пустым, если не нужен.${NC}"
    read -p "AD TAG (32 hex символа или Enter для пропуска): " tag
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

    # Создаем файлы
    generate_docker_compose "$port"
    
    if ! generate_config "$port" "$secret" "$domain" "$tag" "$public_host" "$username"; then
        echo -e "${RED}[!] Ошибка создания конфигурации${NC}"
        return 1
    fi
    
    if ! start_docker_container; then
        echo -e "${RED}[!] Ошибка запуска контейнера${NC}"
        return 1
    fi
    
    # Диагностика сети
    network_diagnostics "$port" "$public_host"
    
    echo -e "\n${GREEN}=== УСТАНОВКА ЗАВЕРШЕНА! ===${NC}"
    echo -e "${CYAN}📁 Директория: $DOCKER_DIR${NC}"
    echo -e "${CYAN}🔧 Управление: cd $DOCKER_DIR && docker compose [up|down|logs|restart]${NC}"
    
    # Показываем данные для подключения
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
                cd "$DOCKER_DIR" && docker compose restart
                sleep 5
                echo -e "${GREEN}[+] AD TAG обновлен, контейнер перезапущен${NC}"
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
                docker compose restart
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
                cd "$DOCKER_DIR" 2>/dev/null && docker compose down -v 2>/dev/null
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
