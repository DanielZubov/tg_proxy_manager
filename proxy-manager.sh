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
        echo -e "${GREEN}[+] Создана директория $CONFIG_DIR${NC}"
    fi
}

# Проверка порта
is_port_free() {
    ! ss -tuln | grep -q ":$1 "
}

# Автоматический поиск свободного порта (вывод ТОЛЬКО в stderr, возврат через stdout)
find_free_port() {
    echo -e "${YELLOW}[*] Автоматический поиск свободного порта...${NC}" >&2
    
    for port in "${PREFERRED_PORTS[@]}"; do
        if is_port_free "$port"; then
            echo -e "${GREEN}[+] Найден свободный порт: $port${NC}" >&2
            echo "$port"
            return 0
        else
            echo -e "${YELLOW}    Порт $port занят, пробуем следующий...${NC}" >&2
        fi
    done
    
    # Если все приоритетные заняты, ищем любой свободный
    echo -e "${YELLOW}[*] Все приоритетные порты заняты. Поиск любого свободного...${NC}" >&2
    for port in $(seq 10000 11000); do
        if is_port_free "$port"; then
            echo -e "${GREEN}[+] Найден свободный порт: $port (из диапазона 10000-11000)${NC}" >&2
            echo "$port"
            return 0
        fi
    done
    
    echo -e "${RED}[!] Не удалось найти свободный порт!${NC}" >&2
    return 1
}

# Проверка и настройка файрвола
check_firewall() {
    local port=$1
    echo -e "${YELLOW}[*] Проверка файрвола...${NC}"
    
    # Проверяем ufw
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        echo -e "${YELLOW}[*] UFW активен. Открываю порт $port...${NC}"
        ufw allow "$port/tcp" 2>/dev/null && echo -e "${GREEN}[+] Правило UFW добавлено${NC}"
    fi
    
    # Проверяем iptables
    if command -v iptables &>/dev/null; then
        if ! iptables -L INPUT -n 2>/dev/null | grep -q "dpt:$port"; then
            echo -e "${YELLOW}[*] Добавляю правило iptables для порта $port...${NC}"
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && echo -e "${GREEN}[+] Правило iptables добавлено${NC}"
        fi
    fi
    
    # Проверяем firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo -e "${YELLOW}[*] Firewalld активен. Открываю порт $port...${NC}"
        firewall-cmd --permanent --add-port="$port/tcp" 2>/dev/null
        firewall-cmd --reload 2>/dev/null
        echo -e "${GREEN}[+] Правило firewalld добавлено${NC}"
    fi
}

# Валидация доменного имени или IP
validate_public_host() {
    local host=$1
    
    # Проверка на IP адрес
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    
    # Проверка на доменное имя
    if [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        if host "$host" &>/dev/null; then
            return 0
        else
            echo -e "${RED}[!] Домен $host не резолвится в DNS${NC}"
            return 1
        fi
    fi
    
    echo -e "${RED}[!] Некорректный формат: $host${NC}"
    return 1
}

# --- УСТАНОВКА БИНАРНИКА ---
install_binary() {
    echo -e "${YELLOW}[*] Установка зависимостей и бинарника...${NC}"
    
    # Установка пакетов
    DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null
    apt-get install -y -qq wget tar xxd qrencode openssl curl jq iproute2 host dnsutils 2>/dev/null
    
    # Определение архитектуры
    ARCH=$(uname -m)
    LIBC_TYPE=$(ldd --version 2>&1 | grep -iq musl && echo "musl" || echo "gnu")
    URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC_TYPE}.tar.gz"
    
    echo -e "${YELLOW}[*] Скачивание telemt...${NC}"
    echo -e "${BLUE}URL: $URL${NC}"
    
    # Создаем временную директорию для распаковки
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    if wget -qO telemt.tar.gz "$URL" 2>/dev/null; then
        tar -xzf telemt.tar.gz 2>/dev/null
        if [ -f telemt ]; then
            mv -f telemt "$BINARY_PATH"
            chmod +x "$BINARY_PATH"
            echo -e "${GREEN}[+] Бинарник установлен в $BINARY_PATH${NC}"
            rm -rf "$TMP_DIR"
        else
            echo -e "${RED}[!] Архив распакован, но бинарник не найден${NC}"
            ls -la "$TMP_DIR"
            rm -rf "$TMP_DIR"
            return 1
        fi
    else
        echo -e "${RED}[!] Ошибка загрузки! Проверьте URL${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    # Создание пользователя
    if ! id -u telemt >/dev/null 2>&1; then
        useradd -d /opt/telemt -m -r -U telemt 2>/dev/null
        echo -e "${GREEN}[+] Пользователь telemt создан${NC}"
    fi
    
    init_dirs
    chown -R telemt:telemt "$CONFIG_DIR" 2>/dev/null
    chown -R telemt:telemt /opt/telemt 2>/dev/null
    
    return 0
}

# --- ГЕНЕРАЦИЯ КОНФИГА (чистый TOML без мусора) ---
generate_config() {
    local port=$1
    local secret=$2
    local domain=$3
    local tag=$4
    local public_host=$5
    
    # Валидация параметров
    if [ -z "$public_host" ] || [ -z "$port" ] || [ -z "$secret" ] || [ -z "$domain" ] || [ -z "$tag" ]; then
        echo -e "${RED}[!] Ошибка: не все параметры указаны${NC}"
        echo -e "DEBUG: host='$public_host' port='$port' secret='$secret' domain='$domain' tag='$tag'"
        return 1
    fi
    
    echo -e "${YELLOW}[*] Создание конфигурации...${NC}"
    
    # Создаем конфиг с ПРАВИЛЬНЫМ форматированием
    cat > "$CONFIG_FILE" << EOF
[general]
use_middle_proxy = true
ad_tag = "$tag"
log_level = "debug"

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
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}[!] Ошибка записи конфига${NC}"
        return 1
    fi
    
    # Проверка конфига на мусор
    if grep -q "\[*\]" "$CONFIG_FILE" || grep -q "\[+\]" "$CONFIG_FILE" || grep -q "\[!\]" "$CONFIG_FILE"; then
        echo -e "${RED}[!] Обнаружен мусор в конфиге!${NC}"
        echo -e "${YELLOW}[*] Содержимое конфига:${NC}"
        cat "$CONFIG_FILE"
        return 1
    fi
    
    # Устанавливаем права
    chown telemt:telemt "$CONFIG_FILE" 2>/dev/null
    chmod 640 "$CONFIG_FILE" 2>/dev/null
    
    echo -e "${GREEN}[+] Конфиг создан успешно${NC}"
    echo -e "${BLUE}[i] Проверка конфига:${NC}"
    echo -e "${BLUE}    public_host = $public_host${NC}"
    echo -e "${BLUE}    public_port = $port${NC}"
    echo -e "${BLUE}    tls_domain = $domain${NC}"
    
    return 0
}

# --- СОЗДАНИЕ СЛУЖБЫ ---
manage_service() {
    echo -e "${YELLOW}[*] Настройка systemd сервиса...${NC}"
    
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
    
    echo -e "${YELLOW}[*] Запуск сервиса...${NC}"
    systemctl restart telemt
    sleep 2
    
    if systemctl is-active --quiet telemt; then
        echo -e "${GREEN}[+] Сервис telemt запущен успешно${NC}"
        
        # Показываем информацию
        echo -e "\n${BLUE}=== Открытые порты ===${NC}"
        ss -tlnp 2>/dev/null | grep -E "telemt|$(cat $PORT_FILE 2>/dev/null)" || echo "Не удалось определить"
        
        return 0
    else
        echo -e "${RED}[!] Сервис не запустился${NC}"
        echo -e "${YELLOW}[*] Статус:${NC}"
        systemctl status telemt --no-pager -l
        echo -e "\n${YELLOW}[*] Последние логи:${NC}"
        journalctl -u telemt -n 20 --no-pager
        return 1
    fi
}

# --- МЕНЮ УСТАНОВКИ ---
menu_install() {
    clear
    echo -e "${CYAN}=== Установка Telemt Proxy ===${NC}"
    
    init_dirs

    # 1. Выбор Fake TLS домена
    echo -e "\n${YELLOW}Шаг 1: Выберите Fake TLS домен${NC}"
    echo -e "${BLUE}(Это домен для маскировки трафика, не ваш реальный)${NC}"
    echo "1) petrovich.ru (default)"
    echo "2) google.com"
    echo "3) github.com"
    echo "4) microsoft.com"
    echo "5) Свой вариант"
    read -p "Выбор (1-5): " d_idx
    case $d_idx in
        2) domain="google.com" ;;
        3) domain="github.com" ;;
        4) domain="microsoft.com" ;;
        5) 
            while true; do
                read -p "Введите домен (например: cdn.example.com): " domain
                if [ -z "$domain" ]; then
                    echo -e "${RED}[!] Домен не может быть пустым${NC}"
                elif ! [[ "$domain" =~ \.[a-zA-Z]{2,}$ ]]; then
                    echo -e "${RED}[!] Введите корректный домен${NC}"
                else
                    break
                fi
            done
            ;;
        *) domain="petrovich.ru" ;;
    esac
    
    echo "$domain" > "$DOMAIN_FILE"
    echo -e "${GREEN}[+] Fake TLS домен: $domain${NC}"

    # 2. Публичный адрес
    echo -e "\n${YELLOW}Шаг 2: Настройка публичного адреса${NC}"
    echo -e "${BLUE}(Это адрес, по которому клиенты будут подключаться к прокси)${NC}"
    
    # Получаем IP разными способами
    server_ip=$(curl -s -4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ -z "$server_ip" ]; then
        server_ip=$(curl -s -4 --connect-timeout 5 https://ifconfig.me 2>/dev/null)
    fi
    if [ -z "$server_ip" ]; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    if [ -z "$server_ip" ]; then
        echo -e "${RED}[!] Не удалось определить IP сервера${NC}"
        read -p "Введите IP вручную: " server_ip
    fi
    
    echo -e "${CYAN}Текущий IP сервера: $server_ip${NC}"
    echo ""
    echo "1) Использовать IP сервера ($server_ip)"
    echo "2) Ввести другой IP"
    echo "3) Использовать свой домен (если настроен DNS)"
    read -p "Выбор (1-3): " host_choice
    
    case $host_choice in
        2)
            while true; do
                read -p "Введите IP адрес: " public_host
                if [[ "$public_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    break
                else
                    echo -e "${RED}[!] Некорректный IP адрес${NC}"
                fi
            done
            ;;
        3)
            while true; do
                read -p "Введите ваш домен (например: proxy.example.com): " public_host
                if validate_public_host "$public_host"; then
                    echo -e "${GREEN}[+] Домен $public_host принят${NC}"
                    echo -e "${YELLOW}[!] Убедитесь, что A-запись домена указывает на IP: $server_ip${NC}"
                    break
                fi
            done
            ;;
        *)
            public_host="$server_ip"
            ;;
    esac
    
    echo "$public_host" > "$PUBLIC_HOST_FILE"
    echo -e "${GREEN}[+] Публичный адрес: $public_host${NC}"

    # 3. Автоматический подбор порта
    echo -e "\n${YELLOW}Шаг 3: Автоматический подбор порта${NC}"
    
    # Вызываем find_free_port, весь вывод идет в stderr, только порт в stdout
    free_port=$(find_free_port 2>&1)
    # Извлекаем только число из возможного мусора
    free_port=$(echo "$free_port" | grep -oE '[0-9]+' | tail -1)
    
    if [ -z "$free_port" ] || [ "$free_port" -lt 1 ] || [ "$free_port" -gt 65535 ]; then
        echo -e "${RED}[!] Не удалось найти свободный порт автоматически${NC}"
        while true; do
            read -p "Введите порт вручную: " free_port
            if [[ "$free_port" =~ ^[0-9]+$ ]] && [ "$free_port" -ge 1 ] && [ "$free_port" -le 65535 ]; then
                if is_port_free "$free_port"; then
                    break
                else
                    echo -e "${RED}[!] Порт $free_port занят${NC}"
                fi
            else
                echo -e "${RED}[!] Некорректный порт (1-65535)${NC}"
            fi
        done
    else
        read -p "Использовать порт $free_port? (Y/n): " port_confirm
        if [ "$port_confirm" = "n" ] || [ "$port_confirm" = "N" ]; then
            while true; do
                read -p "Введите порт вручную: " free_port
                if [[ "$free_port" =~ ^[0-9]+$ ]] && [ "$free_port" -ge 1 ] && [ "$free_port" -le 65535 ]; then
                    if is_port_free "$free_port"; then
                        break
                    else
                        echo -e "${RED}[!] Порт $free_port занят${NC}"
                    fi
                else
                    echo -e "${RED}[!] Некорректный порт${NC}"
                fi
            done
        fi
    fi
    
    echo "$free_port" > "$PORT_FILE"
    echo -e "${GREEN}[+] Выбран порт: $free_port${NC}"
    
    # Проверка файрвола
    check_firewall "$free_port"

    # 4. Генерация секретов
    echo -e "\n${YELLOW}Шаг 4: Генерация ключей безопасности${NC}"
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    echo -e "${GREEN}[+] Secret ключ сгенерирован: ${secret:0:8}...${NC}"
    
    # Тег
    if [ -f "$TAG_FILE" ] && [ -s "$TAG_FILE" ]; then
        tag=$(cat "$TAG_FILE")
        echo -e "${GREEN}[+] Использован существующий AD TAG: $tag${NC}"
    else
        tag="00000000000000000000000000000000"
        echo "$tag" > "$TAG_FILE"
        echo -e "${YELLOW}[*] Создан AD TAG по умолчанию${NC}"
    fi
    
    # Сохраняем IP
    echo "$server_ip" > "$IP_FILE"
    
    echo -e "\n${CYAN}=== Начало установки ===${NC}"
    echo -e "${YELLOW}Параметры:${NC}"
    echo -e "  Публичный адрес: ${GREEN}$public_host${NC}"
    echo -e "  Порт: ${GREEN}$free_port${NC}"
    echo -e "  Fake TLS: ${GREEN}$domain${NC}"
    echo -e "  AD TAG: ${GREEN}$tag${NC}"
    echo ""

    # Установка
    if ! install_binary; then
        echo -e "${RED}[!] КРИТИЧЕСКАЯ ОШИБКА: установка бинарника${NC}"
        return 1
    fi
    
    if ! generate_config "$free_port" "$secret" "$domain" "$tag" "$public_host"; then
        echo -e "${RED}[!] КРИТИЧЕСКАЯ ОШИБКА: создание конфига${NC}"
        return 1
    fi
    
    if ! manage_service; then
        echo -e "${RED}[!] КРИТИЧЕСКАЯ ОШИБКА: запуск сервиса${NC}"
        echo -e "${YELLOW}[*] Проверьте конфиг вручную:${NC}"
        echo -e "cat $CONFIG_FILE"
        return 1
    fi
    
    echo -e "\n${GREEN}=== Установка успешно завершена! ===${NC}"
    
    # Важная информация
    echo -e "\n${BLUE}=== ВАЖНО: Действия для подключения ===${NC}"
    echo -e "1. Убедитесь, что порт ${CYAN}$free_port${NC} открыт в облачном фаерволе"
    echo -e "2. Проверьте доступность снаружи:"
    echo -e "   ${CYAN}curl -v https://$public_host:$free_port${NC}"
    echo -e "3. Если используется домен, проверьте DNS:"
    echo -e "   ${CYAN}host $public_host${NC}"
    
    show_data
    read -p "Нажмите Enter для продолжения..."
}

# --- ВЫВОД ДАННЫХ ---
show_data() {
    if ! systemctl is-active --quiet telemt; then 
        echo -e "${RED}[!] Сервис не запущен!${NC}"
        echo -e "${YELLOW}[*] Запустите: systemctl start telemt${NC}"
        return
    fi
    
    echo -e "\n${GREEN}=== Данные для подключения ===${NC}"
    
    # Ждем API
    echo -e "${YELLOW}[*] Ожидание готовности API...${NC}"
    for i in {1..15}; do
        if curl -s http://127.0.0.1:9091/v1/users >/dev/null 2>&1; then
            echo -e "${GREEN}[+] API готов${NC}"
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    
    RAW_DATA=$(curl -s http://127.0.0.1:9091/v1/users)
    if [ -z "$RAW_DATA" ]; then
        echo -e "${RED}[!] API не отвечает${NC}"
        echo -e "${YELLOW}[*] Попробуйте позже: systemctl restart telemt${NC}"
        return
    fi
    
    # Парсим ссылки
    echo -e "\n${CYAN}Ссылки для подключения:${NC}"
    echo "$RAW_DATA" | jq -r '.data[0].links.tls[]' 2>/dev/null | while read link; do
        if [ ! -z "$link" ] && [ "$link" != "null" ]; then
            echo -e "${GREEN}$link${NC}"
            echo ""
            qrencode -t ANSIUTF8 "$link" 2>/dev/null
            echo ""
        fi
    done
    
    # Дополнительная диагностика
    echo -e "\n${BLUE}=== Диагностика ===${NC}"
    echo -e "Конфиг: $CONFIG_FILE"
    echo -e "Содержимое конфига:"
    cat "$CONFIG_FILE" 2>/dev/null | head -15
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root
init_dirs

while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Telemt Proxy Manager v2.1       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo "1) 🚀 Установить / Обновить прокси"
    echo "2) 📱 Показать QR-коды и ссылки"
    echo "3) 🏷️  Изменить AD TAG"
    echo "4) 📊 Статус и логи сервиса"
    echo "5) 🔄 Перезапустить сервис"
    echo "6) 🔍 Диагностика подключения"
    echo "7) 📝 Показать конфиг"
    echo "8) 🗑️  Полное удаление"
    echo "0) Выход"
    echo ""
    
    if systemctl is-active --quiet telemt 2>/dev/null; then
        echo -e "${GREEN}● Сервис активен${NC}"
    else
        echo -e "${RED}● Сервис не запущен${NC}"
    fi
    
    read -p "Выбор: " idx
    
    case $idx in
        1) 
            # Останавливаем сервис перед переустановкой
            systemctl stop telemt 2>/dev/null
            menu_install 
            ;;
        2) 
            show_data
            read -p "Нажмите Enter..." 
            ;;
        3) 
            read -p "Введите AD TAG (32 hex символа): " nt
            if [ ${#nt} -eq 32 ] && [[ "$nt" =~ ^[0-9a-fA-F]+$ ]]; then
                echo "$nt" > "$TAG_FILE"
                if [ -f "$PORT_FILE" ] && [ -f "$SECRET_FILE" ] && [ -f "$DOMAIN_FILE" ] && [ -f "$PUBLIC_HOST_FILE" ]; then
                    port=$(cat "$PORT_FILE")
                    secret=$(cat "$SECRET_FILE")
                    domain=$(cat "$DOMAIN_FILE")
                    public_host=$(cat "$PUBLIC_HOST_FILE")
                    
                    generate_config "$port" "$secret" "$domain" "$nt" "$public_host"
                    systemctl restart telemt
                    echo -e "${GREEN}[+] AD TAG обновлен!${NC}"
                else
                    echo -e "${RED}[!] Не найдены файлы конфигурации. Выполните установку${NC}"
                fi
            else
                echo -e "${RED}[!] TAG должен быть 32 символа (0-9, a-f)${NC}"
            fi
            sleep 2 
            ;;
        4) 
            echo -e "${YELLOW}=== Статус сервиса ===${NC}"
            systemctl status telemt --no-pager -l
            echo -e "\n${YELLOW}=== Последние логи (30 строк) ===${NC}"
            journalctl -u telemt -n 30 --no-pager
            read -p "Нажмите Enter..." 
            ;;
        5)
            echo -e "${YELLOW}[*] Перезапуск сервиса...${NC}"
            systemctl restart telemt
            sleep 2
            if systemctl is-active --quiet telemt; then
                echo -e "${GREEN}[+] Сервис перезапущен${NC}"
            else
                echo -e "${RED}[!] Ошибка перезапуска${NC}"
                journalctl -u telemt -n 10 --no-pager
            fi
            sleep 2
            ;;
        6)
            echo -e "${YELLOW}=== Диагностика подключения ===${NC}"
            
            port=$(cat "$PORT_FILE" 2>/dev/null || echo "неизвестен")
            public_host=$(cat "$PUBLIC_HOST_FILE" 2>/dev/null || echo "неизвестен")
            
            echo -e "Публичный адрес: ${CYAN}$public_host:$port${NC}"
            
            # Проверка порта локально
            echo -e "\n${YELLOW}Локальные слушающие порты:${NC}"
            if ss -tlnp 2>/dev/null | grep -q ":$port "; then
                echo -e "${GREEN}[+] Порт $port слушается локально${NC}"
                ss -tlnp | grep ":$port "
            else
                echo -e "${RED}[!] Порт $port не слушается${NC}"
            fi
            
            # Проверка файрвола
            echo -e "\n${YELLOW}Правила iptables:${NC}"
            iptables -L INPUT -n 2>/dev/null | grep "dpt:$port" || echo "Нет правил для порта $port"
            
            # Проверка DNS для доменов
            if [[ ! "$public_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "\n${YELLOW}DNS резолвинг:${NC}"
                host "$public_host" 2>&1
            fi
            
            # Активные подключения
            echo -e "\n${YELLOW}Активные подключения telemt:${NC}"
            ss -tnp 2>/dev/null | grep telemt | head -5 || echo "Нет активных подключений"
            
            # Проверка конфига
            echo -e "\n${YELLOW}Валидация конфига:${NC}"
            if [ -f "$CONFIG_FILE" ]; then
                if grep -q "^public_port = [0-9]" "$CONFIG_FILE"; then
                    echo -e "${GREEN}[+] Конфиг выглядит корректно${NC}"
                else
                    echo -e "${RED}[!] Проблема в конфиге! Содержимое:${NC}"
                    head -15 "$CONFIG_FILE"
                fi
            fi
            
            read -p "Нажмите Enter..."
            ;;
        7)
            echo -e "${YELLOW}=== Содержимое конфига ===${NC}"
            if [ -f "$CONFIG_FILE" ]; then
                cat "$CONFIG_FILE"
            else
                echo -e "${RED}[!] Конфиг не найден${NC}"
            fi
            read -p "Нажмите Enter..."
            ;;
        8) 
            echo -e "${RED}[!] ВНИМАНИЕ: Полное удаление Telemt!${NC}"
            read -p "Введите 'yes' для подтверждения: " confirm
            if [ "$confirm" = "yes" ]; then
                systemctl stop telemt 2>/dev/null
                systemctl disable telemt 2>/dev/null
                rm -f "$SERVICE_FILE"
                rm -f "$BINARY_PATH"
                rm -rf "$CONFIG_DIR"
                userdel -r telemt 2>/dev/null
                systemctl daemon-reload
                echo -e "${GREEN}[+] Система полностью очищена${NC}"
            fi
            sleep 2 
            ;;
        0) 
            echo -e "${GREEN}До свидания!${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}[!] Неверный выбор${NC}"
            sleep 1 
            ;;
    esac
done
