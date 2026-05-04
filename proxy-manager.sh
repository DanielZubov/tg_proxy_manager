#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
BINARY_PATH="/usr/local/bin/proxy-manager"
CONFIG_FILE="/etc/proxy_public_domain.conf"
TAG_FILE="/etc/proxy_ad_tag.conf"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
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

# Функция получения параметров текущего контейнера
get_current_params() {
    CMD_ARGS=$(docker inspect mtproto-proxy --format='{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null)
    # Секрет всегда последний
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

    LINK="tg://proxy?server=$HOST&port=$CUR_PORT&secret=$CUR_SECRET"

    echo -e "\n${GREEN}=== ТЕКУЩИЕ НАСТРОЙКИ ПРОКСИ ===${NC}"
    echo -e "Адрес (Host): ${CYAN}$HOST${NC}"
    echo -e "Порт: ${CYAN}$CUR_PORT${NC}"
    echo -e "Секрет: ${CYAN}$CUR_SECRET${NC}"
    echo -e "AD TAG: ${MAGENTA}$AD_TAG${NC}"
    echo -e "Ссылка: ${BLUE}$LINK${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$LINK"
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

    # Подбор порта
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

    SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$FAKE_DOMAIN")
    run_container "$PORT" "$SECRET"
}

menu_set_tag() {
    if ! docker ps | grep -q "mtproto-proxy"; then echo -e "${RED}Сначала установите прокси!${NC}"; sleep 2; return; fi
    clear
    echo -e "${MAGENTA}--- Настройка Promotion (AD TAG) ---${NC}"
    echo "1. Откройте @MTProxybot в Telegram"
    echo "2. Зарегистрируйте прокси, используя данные из пункта 2 меню"
    echo "3. Бот выдаст вам HEX-строку (Tag)"
    echo "------------------------------------------------"
    read -p "Введите полученный AD TAG (или нажмите Enter для удаления): " NEW_TAG
    
    if [ -z "$NEW_TAG" ]; then
        rm -f "$TAG_FILE"
        echo "Тег удален."
    else
        echo "$NEW_TAG" > "$TAG_FILE"
        echo "Тег сохранен."
    fi

    get_current_params
    run_container "$CUR_PORT" "$CUR_SECRET"
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

# --- СТАРТ ---
check_root
install_deps

while true; do
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e "${WHITE}    MTProto Proxy Manager PRO         ${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "1) ${GREEN}Установить / Обновить (Сброс)${NC}"
    echo -e "2) Показать данные для @MTProxybot${NC}"
    echo -e "3) ${MAGENTA}Настроить / Изменить AD TAG${NC}"
    echo -e "4) ${RED}Удалить прокси${NC}"
    echo -e "0) Выход${NC}"
    read -p "Выберите пункт: " m_idx
    case $m_idx in
        1) menu_install ;;
        2) clear; show_config; read -p "Нажмите Enter..." ;;
        3) menu_set_tag ;;
        4) docker stop mtproto-proxy &>/dev/null && docker rm mtproto-proxy &>/dev/null; rm -f "$CONFIG_FILE" "$TAG_FILE"; echo "Удалено"; sleep 1 ;;
        0) exit 0 ;;
    esac
done
