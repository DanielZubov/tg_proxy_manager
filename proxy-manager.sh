#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
BINARY_PATH="/usr/local/bin/proxy-manager"
CONFIG_FILE="/etc/proxy_public_domain.conf"
TAG_FILE="/etc/proxy_ad_tag.conf"
BASE_SECRET_FILE="/etc/proxy_base_secret.conf"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Ошибка: запустите через sudo!${NC}"; exit 1; fi
}

install_deps() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}[*] Установка Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi
    if ! command -v qrencode &> /dev/null; then
        echo -e "${YELLOW}[*] Установка qrencode...${NC}"
        apt-get update && apt-get install -y qrencode || yum install -y qrencode
    fi
    cp "$0" "$BINARY_PATH" && chmod +x "$BINARY_PATH"
}

get_ip() {
    curl -s -4 --max-time 5 https://api.ipify.org || echo "0.0.0.0"
}

get_current_params() {
    CMD_ARGS=$(docker inspect mtproto-proxy --format='{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null)
    CUR_SECRET=$(echo $CMD_ARGS | awk '{print $NF}')
    CUR_PORT=$(docker inspect mtproto-proxy --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' 2>/dev/null)
}

show_config() {
    if ! docker ps | grep -q "mtproto-proxy"; then 
        echo -e "${RED}Прокси не запущен!${NC}"
        return
    fi
    
    get_current_params
    
    HOST=$( [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || get_ip )
    AD_TAG=$( [ -f "$TAG_FILE" ] && cat "$TAG_FILE" || echo "отсутствует" )
    # Читаем чистый секрет для бота
    BOT_SECRET=$( [ -f "$BASE_SECRET_FILE" ] && cat "$BASE_SECRET_FILE" || echo "Переустановите прокси (п. 1)" )

    LINK="tg://proxy?server=$HOST&port=$CUR_PORT&secret=$CUR_SECRET"

    echo -e "\n${GREEN}=== ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ (CLIENT) ===${NC}"
    echo -e "Ссылка: ${BLUE}$LINK${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$LINK"

    echo -e "${YELLOW}=== ДАННЫЕ ДЛЯ @MTProxybot (REGISTRATION) ===${NC}"
    echo -e "IP: ${WHITE}$HOST${NC}"
    echo -e "Port: ${WHITE}$CUR_PORT${NC}"
    echo -e "Secret: ${CYAN}$BOT_SECRET${NC} ${RED}<-- Используйте ЭТОТ для бота!${NC}"
    echo -e "AD TAG: ${MAGENTA}$AD_TAG${NC}"
    echo "------------------------------------------------"
}

menu_install() {
    clear
    echo -e "${CYAN}--- Выбор домена Fake TLS ---${NC}"
    domains=("max.ru" "lenta.ru" "rbc.ru" "ria.ru" "kommersant.ru" "yandex.ru" "google.com" "github.com" "wikipedia.org" "habr.com")
    for i in "${!domains[@]}"; do
        printf "${YELLOW}%2d)${NC} %-18s " "$((i+1))" "${domains[$i]}"
        [[ $(( (i+1) % 2 )) -eq 0 ]] && echo ""
    done
    echo -ne "\nВыбор [1-10, default 1]: "
    read d_idx
    FAKE_DOMAIN=${domains[$((d_idx-1))]}
    FAKE_DOMAIN=${FAKE_DOMAIN:-max.ru}

    echo -e "\n${CYAN}--- Настройка публичного адреса ---${NC}"
    read -p "Введите ваш ДОМЕН для ссылки. Пусто = IP: " PUB_HOST
    [ -z "$PUB_HOST" ] && PUB_HOST=$(get_ip)
    echo "$PUB_HOST" > "$CONFIG_FILE"

    PORT=443
    echo -ne "\n🔍 Проверка порта ${PORT}... "
    if ss -tuln | grep -q ":${PORT} "; then
        echo -e "${YELLOW}занят${NC}"
        for alt_port in 9443 8443 8444 8445; do
            if ! ss -tuln | grep -q ":${alt_port} "; then
                PORT=$alt_port
                echo -e "✅ Свободный порт найден: ${GREEN}${PORT}${NC}"
                break
            fi
        done
    else
        echo -e "${GREEN}свободен${NC}"
    fi

    # Генерируем два секрета: один для работы (FakeTLS), другой для бота (HEX)
    BASE_HEX=$(openssl rand -hex 16)
    echo "$BASE_HEX" > "$BASE_SECRET_FILE"
    
    # Генерируем сложный секрет для работы через mtg
    WORK_SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$FAKE_DOMAIN")
    
    run_container "$PORT" "$WORK_SECRET"
}

menu_set_tag() {
    if ! docker ps | grep -q "mtproto-proxy"; then echo -e "${RED}Сначала установите прокси!${NC}"; sleep 2; return; fi
    clear
    echo -e "${MAGENTA}--- Настройка Promotion (AD TAG) ---${NC}"
    echo "1. Используйте данные из п.2 для регистрации у бота."
    echo "2. Бот примет HEX-секрет (32 символа)."
    read -p "Введите полученный AD TAG: " NEW_TAG
    
    if [ ! -z "$NEW_TAG" ]; then
        echo "$NEW_TAG" > "$TAG_FILE"
        get_current_params
        run_container "$CUR_PORT" "$CUR_SECRET"
    fi
}

run_container() {
    local p=$1
    local s=$2
    local t=$( [ -f "$TAG_FILE" ] && cat "$TAG_FILE" )
    
    echo -e "${YELLOW}[*] Запуск контейнера...${NC}"
    docker stop mtproto-proxy &>/dev/null && docker rm mtproto-proxy &>/dev/null
    
    AD_ARG=""
    [ ! -z "$t" ] && AD_ARG="-t $t"

    docker run -d --name mtproto-proxy --restart always -p "$p":"$p" \
        nineseconds/mtg:2 simple-run -n 1.1.1.1 -i prefer-ipv4 $AD_ARG 0.0.0.0:"$p" "$s" > /dev/null
    
    echo -e "${GREEN}Прокси успешно запущен!${NC}"
    show_config
    read -p "Нажмите Enter..."
}

check_root
install_deps

while true; do
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e "${WHITE}    Hikamo Proxy Manager      ${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "1) ${GREEN}Установить прокси (с нуля)${NC}"
    echo -e "2) Показать данные для @MTProxybot${NC}"
    echo -e "3) Настроить AD TAG${NC}"
    echo -e "4) ${RED}Удалить прокси${NC}"
    echo -e "0) Выход${NC}"
    read -p "Выберите пункт: " m_idx
    case $m_idx in
        1) menu_install ;;
        2) clear; show_config; read -p "Нажмите Enter..." ;;
        3) menu_set_tag ;;
        4) docker stop mtproto-proxy &>/dev/null && docker rm mtproto-proxy &>/dev/null; rm -f "$CONFIG_FILE" "$TAG_FILE" "$BASE_SECRET_FILE"; echo "Удалено"; sleep 1 ;;
        0) exit 0 ;;
    esac
done
