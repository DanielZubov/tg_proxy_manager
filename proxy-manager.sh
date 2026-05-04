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

# Автоматический поиск свободного порта
find_free_port() {
    echo -e "${YELLOW}[*] Автоматический поиск свободного порта...${NC}"
    
    for port in "${PREFERRED_PORTS[@]}"; do
        if is_port_free "$port"; then
            echo -e "${GREEN}[+] Найден свободный порт: $port${NC}"
            echo "$port"
            return 0
        else
            echo -e "${YELLOW}    Порт $port занят, пробуем следующий...${NC}"
        fi
    done
    
    # Если все приоритетные заняты, ищем любой свободный
    echo -e "${YELLOW}[*] Все приоритетные порты заняты. Поиск любого свободного...${NC}"
    for port in $(seq 10000 11000); do
        if is_port_free "$port"; then
            echo -e "${GREEN}[+] Найден свободный порт: $port (из диапазона 10000-11000)${NC}"
            echo "$port"
            return 0
        fi
    done
    
    echo -e "${RED}[!] Не удалось найти свободный порт!${NC}"
    return 1
}

# Проверка доступности порта снаружи (эвристика)
check_external_access() {
    local port=$1
    echo -e "${YELLOW}[*] Проверка доступности порта $port снаружи...${NC}"
    
    # Пробуем получить свой внешний IP
    local ext_ip=$(curl -s -4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ -z "$ext_ip" ]; then
        echo -e "${RED}[!] Не удалось определить внешний IP${NC}"
        return 1
    fi
    
    # Проверяем через онлайн-сервисы проверки портов
    if command -v timeout &>/dev/null; then
        local check_result=$(timeout 10 curl -s "https://portchecker.co/check?host=$ext_ip&port=$port" 2>/dev/null | grep -o '"open":true' || echo "failed")
        if [[ "$check_result" == *"true"* ]]; then
            echo -e "${GREEN}[+] Порт $port доступен снаружи${NC}"
            return 0
        fi
    fi
    
    # Альтернативная проверка через nmap если есть
    if command -v nmap &>/dev/null; then
        echo -e "${YELLOW}[*] Проверка через nmap...${NC}"
        if nmap -p "$port" "$ext_ip" 2>/dev/null | grep -q "open"; then
            echo -e "${GREEN}[+] Порт $port открыт${NC}"
            return 0
        fi
    fi
    
    echo -e "${YELLOW}[!] Не удалось подтвердить доступность порта снаружи${NC}"
    echo -e "${YELLOW}[!] Проверьте файрвол (iptables/ufw) и безопасность облака${NC}"
    return 0  # Не блокируем установку, просто предупреждаем
}

# Проверка и настройка файрвола
check_firewall() {
    local port=$1
    echo -e "${YELLOW}[*] Проверка файрвола...${NC}"
    
    # Проверяем ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        echo -e "${YELLOW}[*] UFW активен. Открываю порт $port...${NC}"
        ufw allow "$port/tcp" 2>/dev/null
        echo -e "${GREEN}[+] Правило UFW добавлено${NC}"
    fi
    
    # Проверяем iptables
    if command -v iptables &>/dev/null; then
        if ! iptables -L INPUT -n | grep -q "dpt:$port"; then
            echo -e "${YELLOW}[*] Добавляю правило iptables для порта $port...${NC}"
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
            echo -e "${GREEN}[+] Правило iptables добавлено${NC}"
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
    
    # Проверка на доменное имя (простая)
    if [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        # Проверяем, что домен резолвится
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
    apt-get update -qq && apt-get install -y wget tar xxd qrencode openssl curl jq iproute2 host dnsutils >/dev/null 2>&1

    ARCH=$(uname -m)
    LIBC_TYPE=$(ldd --version 2>&1 | grep -iq musl && echo "musl" || echo "gnu")
    URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC_TYPE}.tar.gz"
    
    echo -e "${YELLOW}[*] Скачивание: $URL${NC}"
    if wget -qO- "$URL" | tar -xz; then
        mv -f telemt "$BINARY_PATH"
        chmod +x "$BINARY_PATH"
        echo -e "${GREEN}[+] Бинарник установлен в $BINARY_PATH${NC}"
    else
        echo -e "${RED}[!] Ошибка загрузки бинарника! Проверьте URL${NC}"
        return 1
    fi
    
    if ! id -u telemt >/dev/null 2>&1; then
        useradd -d /opt/telemt -m -r -U telemt
        echo -e "${GREEN}[+] Пользователь telemt создан${NC}"
    fi
    
    init_dirs
    chown -R telemt:telemt "$CONFIG_DIR"
}

# --- ГЕНЕРАЦИЯ КОНФИГА ---
generate_config() {
    local port=$1
    local secret=$2
    local domain=$3
    local tag=$4
    local public_host=$5
    
    # Валидация public_host
    if [ -z "$public_host" ]; then
        echo -e "${RED}[!] Публичный адрес не указан${NC}"
        return 1
    fi

    cat <<EOF > "$CONFIG_FILE"
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
    
    if [ $? -eq 0 ]; then
        chown telemt:telemt "$CONFIG_FILE"
        echo -e "${GREEN}[+] Конфиг создан: $CONFIG_FILE${NC}"
        echo -e "${BLUE}[i] Публичный хост: $public_host:$port${NC}"
        echo -e "${BLUE}[i] Fake TLS домен: $domain${NC}"
    else
        echo -e "${RED}[!] Ошибка создания конфига${NC}"
        return 1
    fi
}

# --- СОЗДАНИЕ СЛУЖБЫ ---
manage_service() {
    cat <<EOF > "$SERVICE_FILE"
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
    systemctl enable telemt
    systemctl restart telemt
    
    echo -e "${YELLOW}[*] Ожидание запуска сервиса...${NC}"
    sleep 3
    
    if systemctl is-active --quiet telemt; then
        echo -e "${GREEN}[+] Сервис telemt запущен успешно${NC}"
        
        # Показываем информацию для диагностики
        echo -e "\n${BLUE}=== Информация для диагностики ===${NC}"
        echo -e "Слушающие порты:"
        ss -tlnp | grep "$BINARY_PATH" || echo "Не удалось определить"
        
        # Проверяем API
        if curl -s http://127.0.0.1:9091/v1/users >/dev/null 2>&1; then
            echo -e "${GREEN}[+] API доступен на 127.0.0.1:9091${NC}"
        else
            echo -e "${YELLOW}[!] API пока недоступен (может потребоваться время)${NC}"
        fi
    else
        echo -e "${RED}[!] Сервис не запустился${NC}"
        echo -e "${YELLOW}[*] Логи для диагностики:${NC}"
        journalctl -u telemt -n 10 --no-pager
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
    read -p "Выбор: " d_idx
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

    # 2. Публичный адрес (ВАЖНОЕ ИСПРАВЛЕНИЕ!)
    echo -e "\n${YELLOW}Шаг 2: Настройка публичного адреса${NC}"
    echo -e "${BLUE}(Это адрес, по которому клиенты будут подключаться)${NC}"
    
    # Определяем IP сервера
    server_ip=$(curl -s -4 --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    if [ -z "$server_ip" ]; then
        server_ip=$(hostname -I | awk '{print $1}')
    fi
    
    echo -e "${CYAN}IP сервера: $server_ip${NC}"
    echo ""
    echo "1) Использовать IP сервера ($server_ip)"
    echo "2) Использовать другой IP"
    echo "3) Использовать свой домен (рекомендуется!)"
    read -p "Выбор: " host_choice
    
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
                    echo -e "${YELLOW}[!] Убедитесь, что DNS A-запись указывает на IP сервера ($server_ip)${NC}"
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
    
    free_port=$(find_free_port)
    if [ -z "$free_port" ]; then
        echo -e "${RED}[!] Не удалось найти свободный порт${NC}"
        return 1
    fi
    
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
    
    echo "$free_port" > "$PORT_FILE"
    echo -e "${GREEN}[+] Выбран порт: $free_port${NC}"
    
    # Проверка внешней доступности и файрвола
    check_firewall "$free_port"
    check_external_access "$free_port"

    # 4. Генерация секретов
    echo -e "\n${YELLOW}Шаг 4: Генерация ключей безопасности${NC}"
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE"
    echo -e "${GREEN}[+] Secret ключ сгенерирован${NC}"
    
    # Тег
    if [ -f "$TAG_FILE" ]; then
        tag=$(cat "$TAG_FILE")
        echo -e "${GREEN}[+] Использован существующий AD TAG: $tag${NC}"
    else
        tag="00000000000000000000000000000000"
        echo "$tag" > "$TAG_FILE"
        echo -e "${YELLOW}[*] Создан AD TAG по умолчанию${NC}"
    fi
    
    # Сохраняем IP
    echo "$server_ip" > "$IP_FILE"

    # Установка
    echo -e "\n${CYAN}=== Начало установки ===${NC}"
    
    if ! install_binary; then
        echo -e "${RED}[!] Ошибка установки бинарника${NC}"
        return 1
    fi
    
    if ! generate_config "$free_port" "$secret" "$domain" "$tag" "$public_host"; then
        echo -e "${RED}[!] Ошибка генерации конфига${NC}"
        return 1
    fi
    
    if ! manage_service; then
        echo -e "${RED}[!] Ошибка запуска сервиса${NC}"
        return 1
    fi
    
    echo -e "\n${GREEN}=== Установка успешно завершена! ===${NC}"
    
    # Важная диагностика
    echo -e "\n${BLUE}=== ВАЖНО: Проверки подключения ===${NC}"
    echo -e "1. Убедитесь, что в облачном провайдере (Hetzner, AWS, etc.) открыт порт $free_port"
    echo -e "2. Если используете домен, проверьте DNS:"
    echo -e "   ${CYAN}host $public_host${NC}"
    if [ "$public_host" != "$server_ip" ]; then
        echo -e "   Должен возвращать IP: $server_ip"
    fi
    echo -e "3. Для теста выполните с клиента:"
    echo -e "   ${CYAN}curl -v https://$public_host:$free_port${NC}"
    
    show_data
    read -p "Нажмите Enter для продолжения..."
}

# --- ВЫВОД ДАННЫХ ---
show_data() {
    if ! systemctl is-active --quiet telemt; then 
        echo -e "${RED}[!] Сервис не запущен!${NC}"
        return
    fi
    
    echo -e "\n${GREEN}=== Данные для подключения ===${NC}"
    
    # Ждем API
    echo -e "${YELLOW}[*] Получение данных от API...${NC}"
    for i in {1..10}; do
        if curl -s http://127.0.0.1:9091/v1/users >/dev/null 2>&1; then
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    
    RAW_DATA=$(curl -s http://127.0.0.1:9091/v1/users)
    if [ -z "$RAW_DATA" ]; then
        echo -e "${RED}[!] API не отвечает${NC}"
        echo -e "${YELLOW}[*] Попробуйте позже или проверьте логи:${NC}"
        echo -e "journalctl -u telemt -f"
        return
    fi
    
    # Парсим все ссылки
    echo -e "\n${CYAN}Ссылки TLS:${NC}"
    echo "$RAW_DATA" | jq -r '.data[0].links.tls[]' 2>/dev/null | while read link; do
        if [ ! -z "$link" ] && [ "$link" != "null" ]; then
            echo -e "${GREEN}$link${NC}"
            echo ""
            echo -e "${YELLOW}QR-код:${NC}"
            qrencode -t ANSIUTF8 "$link" 2>/dev/null
            echo ""
        fi
    done
    
    # Дополнительная диагностика
    echo -e "\n${BLUE}=== Диагностика ===${NC}"
    echo -e "Конфиг файл: $CONFIG_FILE"
    echo -e "Публичный хост: $(cat $PUBLIC_HOST_FILE 2>/dev/null || echo 'не найден')"
    echo -e "Порт: $(cat $PORT_FILE 2>/dev/null || echo 'не найден')"
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root
init_dirs

while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Telemt Proxy Manager v2.0       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo "1) 🚀 Установить / Обновить прокси"
    echo "2) 📱 Показать QR-коды и ссылки"
    echo "3) 🏷️  Изменить AD TAG"
    echo "4) 📊 Статус и логи сервиса"
    echo "5) 🔄 Перезапустить сервис"
    echo "6) 🔍 Диагностика подключения"
    echo "7) 🗑️  Полное удаление"
    echo "0) Выход"
    echo ""
    
    if systemctl is-active --quiet telemt 2>/dev/null; then
        echo -e "${GREEN}● Сервис активен${NC}"
    else
        echo -e "${RED}● Сервис не запущен${NC}"
    fi
    
    read -p "Выбор: " idx
    
    case $idx in
        1) menu_install ;;
        2) show_data; read -p "Нажмите Enter..." ;;
        3) 
            read -p "Введите AD TAG (hex, 32 символа): " nt
            if [ ${#nt} -eq 32 ] && [[ "$nt" =~ ^[0-9a-fA-F]+$ ]]; then
                echo "$nt" > "$TAG_FILE"
                if [ -f "$PORT_FILE" ] && [ -f "$SECRET_FILE" ] && [ -f "$DOMAIN_FILE" ] && [ -f "$PUBLIC_HOST_FILE" ]; then
                    generate_config "$(cat $PORT_FILE)" "$(cat $SECRET_FILE)" "$(cat $DOMAIN_FILE)" "$nt" "$(cat $PUBLIC_HOST_FILE)"
                    systemctl restart telemt
                    echo -e "${GREEN}[+] AD TAG обновлен!${NC}"
                fi
            else
                echo -e "${RED}[!] TAG должен быть 32 hex-символа${NC}"
            fi
            sleep 2 
            ;;
        4) 
            echo -e "${YELLOW}=== Статус сервиса ===${NC}"
            systemctl status telemt --no-pager
            echo -e "\n${YELLOW}=== Последние логи (30 строк) ===${NC}"
            journalctl -u telemt -n 30 --no-pager
            read -p "Нажмите Enter..." 
            ;;
        5)
            systemctl restart telemt
            sleep 2
            if systemctl is-active --quiet telemt; then
                echo -e "${GREEN}[+] Сервис перезапущен${NC}"
            else
                echo -e "${RED}[!] Ошибка перезапуска${NC}"
            fi
            sleep 2
            ;;
        6)
            echo -e "${YELLOW}=== Диагностика подключения ===${NC}"
            
            port=$(cat "$PORT_FILE" 2>/dev/null || echo "неизвестен")
            public_host=$(cat "$PUBLIC_HOST_FILE" 2>/dev/null || echo "неизвестен")
            
            echo -e "Публичный адрес: $public_host:$port"
            
            # Проверка порта локально
            if ss -tlnp | grep -q ":$port "; then
                echo -e "${GREEN}[+] Порт $port слушается локально${NC}"
            else
                echo -e "${RED}[!] Порт $port не слушается${NC}"
            fi
            
            # Проверка файрвола
            echo -e "\nПравила iptables для порта $port:"
            iptables -L INPUT -n | grep "dpt:$port" || echo "Нет правил"
            
            # Проверка DNS если используется домен
            if [[ "$public_host" =~ [a-zA-Z] ]]; then
                echo -e "\nDNS резолвинг:"
                host "$public_host" 2>&1
            fi
            
            echo -e "\nАктивные подключения к telemt:"
            ss -tnp | grep telemt | head -5
            
            read -p "Нажмите Enter..."
            ;;
        7) 
            echo -e "${RED}[!] ВНИМАНИЕ: Полное удаление Telemt!${NC}"
            read -p "Вы уверены? (yes/N): " confirm
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
