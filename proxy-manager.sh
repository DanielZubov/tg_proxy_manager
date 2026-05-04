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

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- СЛУЖЕБНЫЕ ФУНКЦИИ ---

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Ошибка: запустите от root!${NC}"
        exit 1
    fi
}

# Инициализация директорий
init_dirs() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        echo -e "${GREEN}[+] Создана директория $CONFIG_DIR${NC}"
    fi
}

is_port_free() {
    ! ss -tuln | grep -q ":$1 "
}

# --- УСТАНОВКА БИНАРНИКА (Шаг 1 инструкции) ---
install_binary() {
    echo -e "${YELLOW}[*] Установка зависимостей и бинарника...${NC}"
    apt-get update -qq && apt-get install -y wget tar xxd qrencode openssl curl jq iproute2 >/dev/null 2>&1

    # Официальный метод определения архитектуры и скачивания
    ARCH=$(uname -m)
    LIBC_TYPE=$(ldd --version 2>&1 | grep -iq musl && echo "musl" || echo "gnu")
    URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC_TYPE}.tar.gz"
    
    echo -e "${YELLOW}[*] Скачивание: $URL${NC}"
    if wget -qO- "$URL" | tar -xz; then
        mv telemt "$BINARY_PATH"
        chmod +x "$BINARY_PATH"
        echo -e "${GREEN}[+] Бинарник установлен в $BINARY_PATH${NC}"
    else
        echo -e "${RED}[!] Ошибка загрузки бинарника!${NC}"
        return 1
    fi
    
    # Создание пользователя (Шаг 2 инструкции)
    if ! id -u telemt >/dev/null 2>&1; then
        useradd -d /opt/telemt -m -r -U telemt
        echo -e "${GREEN}[+] Пользователь telemt создан${NC}"
    fi
    
    # Права на конфиг
    init_dirs
    chown -R telemt:telemt "$CONFIG_DIR"
}

# --- ГЕНЕРАЦИЯ КОНФИГА (Шаг 1 инструкции) ---
generate_config() {
    local port=$1
    local secret=$2
    local domain=$3
    local tag=$4
    
    # Получаем IP
    if [ -f "$IP_FILE" ]; then
        host=$(cat "$IP_FILE")
    else
        host=$(curl -s -4 https://api.ipify.org)
        if [ -z "$host" ]; then
            echo -e "${RED}[!] Не удалось определить IP${NC}"
            return 1
        fi
    fi

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
    
    if [ $? -eq 0 ]; then
        chown telemt:telemt "$CONFIG_FILE"
        echo -e "${GREEN}[+] Конфиг создан: $CONFIG_FILE${NC}"
    else
        echo -e "${RED}[!] Ошибка создания конфига${NC}"
        return 1
    fi
}

# --- СОЗДАНИЕ СЛУЖБЫ (Шаг 3 инструкции) ---
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
    
    sleep 2
    if systemctl is-active --quiet telemt; then
        echo -e "${GREEN}[+] Сервис telemt запущен успешно${NC}"
    else
        echo -e "${RED}[!] Сервис не запустился. Проверьте: journalctl -u telemt -n 20${NC}"
    fi
}

# --- МЕНЮ УСТАНОВКИ ---
menu_install() {
    clear
    echo -e "${CYAN}=== Установка Telemt (Official Way) ===${NC}"
    
    # ИНИЦИАЛИЗАЦИЯ ДИРЕКТОРИЙ ПЕРВЫМ ДЕЛОМ
    init_dirs

    # 1. Выбор домена
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
    
    # Проверка, что домен не пустой
    if [ -z "$domain" ]; then
        echo -e "${RED}[!] Домен не может быть пустым${NC}"
        domain="petrovich.ru"
    fi
    
    echo "$domain" > "$DOMAIN_FILE" || {
        echo -e "${RED}[!] Не удалось записать в $DOMAIN_FILE${NC}"
        return 1
    }
    echo -e "${GREEN}[+] Домен: $domain${NC}"

    # 2. Выбор порта
    while true; do
        read -p "Введите порт (по умолчанию 443): " port
        port=${port:-443}
        
        # Проверка, что порт - число
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}[!] Некорректный порт. Введите число от 1 до 65535${NC}"
            continue
        fi
        
        if is_port_free "$port"; then
            break
        else
            echo -e "${RED}[!] Порт $port занят. Выберите другой${NC}"
        fi
    done
    
    echo "$port" > "$PORT_FILE" || {
        echo -e "${RED}[!] Не удалось записать в $PORT_FILE${NC}"
        return 1
    }
    echo -e "${GREEN}[+] Порт: $port${NC}"

    # 3. IP и Секреты
    echo -e "${YELLOW}[*] Определение IP...${NC}"
    host=$(curl -s -4 https://api.ipify.org)
    if [ -z "$host" ]; then
        echo -e "${RED}[!] Не удалось определить IP. Проверьте интернет-соединение${NC}"
        return 1
    fi
    echo "$host" > "$IP_FILE" || {
        echo -e "${RED}[!] Не удалось записать в $IP_FILE${NC}"
        return 1
    }
    echo -e "${GREEN}[+] IP: $host${NC}"
    
    secret=$(openssl rand -hex 16)
    echo "$secret" > "$SECRET_FILE" || {
        echo -e "${RED}[!] Не удалось записать в $SECRET_FILE${NC}"
        return 1
    }
    echo -e "${GREEN}[+] Secret сгенерирован${NC}"
    
    # Проверяем существующий тег или создаем новый
    if [ -f "$TAG_FILE" ]; then
        tag=$(cat "$TAG_FILE")
        echo -e "${GREEN}[+] Использован существующий TAG: $tag${NC}"
    else
        tag="00000000000000000000000000000000"
        echo "$tag" > "$TAG_FILE"
        echo -e "${YELLOW}[*] Создан TAG по умолчанию${NC}"
    fi

    # Выполнение установки
    echo -e "\n${YELLOW}[*] Установка бинарника...${NC}"
    if ! install_binary; then
        echo -e "${RED}[!] Ошибка установки бинарника${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}[*] Генерация конфига...${NC}"
    if ! generate_config "$port" "$secret" "$domain" "$tag"; then
        echo -e "${RED}[!] Ошибка генерации конфига${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}[*] Настройка сервиса...${NC}"
    manage_service
    
    echo -e "\n${GREEN}[+] Установка завершена!${NC}"
    show_data
    read -p "Нажмите Enter для продолжения..."
}

# --- ВЫВОД ДАННЫХ (Шаг 7 инструкции) ---
show_data() {
    if ! systemctl is-active --quiet telemt; then 
        echo -e "${RED}[!] Сервис не запущен! Запустите: systemctl start telemt${NC}"
        echo -e "${YELLOW}[*] Логи: journalctl -u telemt -n 20${NC}"
        return
    fi
    
    echo -e "\n${GREEN}=== ССЫЛКИ ДЛЯ ПОДКЛЮЧЕНИЯ ===${NC}"
    
    # Ждем, пока API станет доступным
    echo -e "${YELLOW}[*] Ожидание API...${NC}"
    for i in {1..5}; do
        if curl -s http://127.0.0.1:9091/v1/users >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    
    RAW_DATA=$(curl -s http://127.0.0.1:9091/v1/users)
    if [ -z "$RAW_DATA" ]; then
        echo -e "${RED}[!] API не отвечает. Проверьте статус сервиса${NC}"
        return
    fi
    
    LINK=$(echo "$RAW_DATA" | jq -r '.data[0].links.tls[0]' 2>/dev/null)

    if [ "$LINK" != "null" ] && [ ! -z "$LINK" ] && [ "$LINK" != "" ]; then
        echo -e "\n${CYAN}Ссылка для подключения:${NC}"
        echo -e "$LINK"
        echo -e "\n${YELLOW}QR-код:${NC}"
        qrencode -t ANSIUTF8 "$LINK"
    else
        echo -e "${RED}[!] Не удалось получить ссылку из API${NC}"
        echo -e "${YELLOW}[*] Ответ API:${NC}"
        echo "$RAW_DATA" | jq '.' 2>/dev/null || echo "$RAW_DATA"
    fi
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root
init_dirs

while true; do
    clear
    echo -e "${CYAN}=== Telemt Manager (Official Guide) ===${NC}"
    echo "1) Установить / Обновить"
    echo "2) Показать QR и ссылки"
    echo "3) Установить AD TAG"
    echo "4) Статус службы и Логи"
    echo "5) Перезапустить сервис"
    echo "6) Полное удаление (Purge)"
    echo "0) Выход"
    read -p "Выбор: " idx
    
    case $idx in
        1) 
            menu_install 
            ;;
        2) 
            show_data
            read -p "Нажмите Enter..." 
            ;;
        3) 
            read -p "Введите AD TAG: " nt
            if [ ! -z "$nt" ]; then
                echo "$nt" > "$TAG_FILE"
                
                # Проверяем наличие файлов
                if [ -f "$PORT_FILE" ] && [ -f "$SECRET_FILE" ] && [ -f "$DOMAIN_FILE" ]; then
                    generate_config "$(cat $PORT_FILE)" "$(cat $SECRET_FILE)" "$(cat $DOMAIN_FILE)" "$nt"
                    systemctl restart telemt
                    echo -e "${GREEN}[+] Тег обновлен!${NC}"
                else
                    echo -e "${RED}[!] Не найдены файлы конфигурации. Выполните установку сначала${NC}"
                fi
            else
                echo -e "${RED}[!] Тег не может быть пустым${NC}"
            fi
            sleep 2 
            ;;
        4) 
            echo -e "${YELLOW}=== Статус сервиса ===${NC}"
            systemctl status telemt --no-pager
            echo -e "\n${YELLOW}=== Последние логи (20 строк) ===${NC}"
            journalctl -u telemt -n 20 --no-pager
            read -p "Нажмите Enter..." 
            ;;
        5)
            echo -e "${YELLOW}[*] Перезапуск сервиса...${NC}"
            systemctl restart telemt
            if systemctl is-active --quiet telemt; then
                echo -e "${GREEN}[+] Сервис перезапущен${NC}"
            else
                echo -e "${RED}[!] Ошибка перезапуска. Проверьте логи${NC}"
            fi
            sleep 2
            ;;
        6) 
            echo -e "${RED}[!] ВНИМАНИЕ: Полное удаление Telemt!${NC}"
            read -p "Вы уверены? (y/N): " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                systemctl stop telemt 2>/dev/null
                systemctl disable telemt 2>/dev/null
                rm -f "$SERVICE_FILE"
                rm -f "$BINARY_PATH"
                rm -rf "$CONFIG_DIR"
                userdel -r telemt 2>/dev/null
                systemctl daemon-reload
                echo -e "${GREEN}[+] Система очищена${NC}"
            else
                echo -e "${YELLOW}[*] Удаление отменено${NC}"
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
