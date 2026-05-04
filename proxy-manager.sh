#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
BINARY_PATH="/usr/local/bin/proxy-manager"
CONFIG_FILE="/etc/proxy_public_domain.conf"

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
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi
    if ! command -v qrencode &> /dev/null; then
        apt-get update && apt-get install -y qrencode || yum install -y qrencode
    fi
    cp "$0" "$BINARY_PATH" && chmod +x "$BINARY_PATH"
}

get_ip() {
    curl -s -4 --max-time 5 https://api.ipify.org || echo "0.0.0.0"
}

show_config() {
    if ! docker ps | grep -q "mtproto-proxy"; then 
        echo -e "${RED}Прокси не запущен!${NC}"
        return
    fi
    
    # Извлекаем данные из запущенного контейнера
    CMD_ARGS=$(docker inspect mtproto-proxy --format='{{range .Config.Cmd}}{{.}} {{end}}')
    SECRET=$(echo $CMD_ARGS | awk '{print $NF}')
    PORT=$(docker inspect mtproto-proxy --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' 2>/dev/null)
    
    if [ -f "$CONFIG_FILE" ]; then
        HOST=$(cat "$CONFIG_FILE")
    else
        HOST=$(get_ip)
    fi

    LINK="tg://proxy?server=$HOST&port=$PORT&secret=$SECRET"

    echo -e "\n${GREEN}=== ТЕКУЩИЕ НАСТРОЙКИ ПРОКСИ ===${NC}"
    echo -e "Адрес (Host): ${CYAN}$HOST${NC}"
    echo -e "Порт: ${CYAN}$PORT${NC}"
    echo -e "Секрет: ${CYAN}$SECRET${NC}"
    echo -e "Ссылка: ${BLUE}$LINK${NC}"
    echo ""
    qrencode -t ANSIUTF8 "$LINK"
}

menu_install() {
    clear
    echo -e "${CYAN}--- Настройка Fake TLS (маскировка) ---${NC}"
    domains=("max.ru" "lenta.ru" "rbc.ru" "ria.ru" "google.com" "github.com")
    for i in "${!domains[@]}"; do
        printf "${YELLOW}%2d)${NC} %-18s " "$((i+1))" "${domains[$i]}"
        [[ $(( (i+1) % 2 )) -eq 0 ]] && echo ""
    done
    echo -ne "\nВыбор домена [1-6, default 1]: "
    read d_idx
    FAKE_DOMAIN=${domains[$((d_idx-1))]}
    FAKE_DOMAIN=${FAKE_DOMAIN:-max.ru}

    echo -e "\n${CYAN}--- Настройка промо-канала ---${NC}"
    echo -e "${YELLOW}Получите тег у @MTProxybot, чтобы закрепить канал в топе${NC}"
    read -p "Введите AD TAG (пусто для пропуска): " AD_TAG

    echo -e "\n${CYAN}--- Настройка публичного адреса ---${NC}"
    read -p "Введите ваш ДОМЕН для ссылки. Пусто = IP: " PUB_HOST
    if [ -z "$PUB_HOST" ]; then PUB_HOST=$(get_ip); fi
    echo "$PUB_HOST" > "$CONFIG_FILE"

    PORT=443
    if ss -tuln | grep -q ":${PORT} "; then
        for alt_port in 9443 8443 8444; do
            if ! ss -tuln | grep -q ":${alt_port} "; then PORT=$alt_port; break; fi
        done
    fi

    echo -e "\n${YELLOW}[*] Настройка прокси...${NC}"
    SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret --hex "$FAKE_DOMAIN")
    
    docker stop mtproto-proxy &>/dev/null && docker rm mtproto-proxy &>/dev/null
    
    # Формируем команду запуска
    # Если AD_TAG не пустой, добавляем аргумент -t
    AD_ARG=""
    if [ ! -z "$AD_TAG" ]; then
        AD_ARG="-t $AD_TAG"
    fi

    docker run -d --name mtproto-proxy --restart always -p "$PORT":"$PORT" \
        nineseconds/mtg:2 simple-run -n 1.1.1.1 -i prefer-ipv4 $AD_ARG 0.0.0.0:"$PORT" "$SECRET" > /dev/null
    
    echo -e "${GREEN}Готово!${NC}"
    show_config
    read -p "Нажмите Enter..."
}

# --- ОСНОВНОЙ ЦИКЛ ---
check_root
install_deps

while true; do
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e "${WHITE}    Hikamo Proxy Manager    ${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo -e "1) ${GREEN}Установить / Обновить прокси${NC}"
    echo -e "2) Показать данные и QR-код${NC}"
    echo -e "3) ${RED}Удалить прокси${NC}"
    echo -e "0) Выход${NC}"
    read -p "Выберите пункт: " m_idx
    case $m_idx in
        1) menu_install ;;
        2) clear; show_config; read -p "Нажмите Enter..." ;;
        3) docker stop mtproto-proxy &>/dev/null && docker rm mtproto-proxy &>/dev/null; rm -f "$CONFIG_FILE"; echo "Удалено"; sleep 1 ;;
        0) exit 0 ;;
    esac
done
