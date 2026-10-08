#!/bin/bash
# ============================================================================
# VLESS + Reality + TCP — восстановление на новом VPS
# Запуск: bash restore.sh <путь_к_params.env_или_URL>
# Пример: bash restore.sh ./params.env
#         bash restore.sh https://example.com/params.env
# ============================================================================
set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Проверка аргумента
if [ $# -lt 1 ]; then
    echo -e "${RED}Использование: bash restore.sh <путь_к_params.env_или_URL>${NC}"
    exit 1
fi

PARAMS_SOURCE="$1"

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ОШИБКА: Скрипт должен быть запущен от root${NC}"
    exit 1
fi

echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   VLESS Reality TCP — Restoration                        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Загрузка параметров
# ============================================================================
echo -e "${GREEN}[1/8] Загрузка параметров...${NC}"
TEMP_PARAMS="/tmp/params.env.$$"

if [[ "$PARAMS_SOURCE" =~ ^https?:// ]]; then
    echo "  Скачивание из URL: $PARAMS_SOURCE"
    curl -sSL "$PARAMS_SOURCE" -o "$TEMP_PARAMS"
else
    if [ ! -f "$PARAMS_SOURCE" ]; then
        echo -e "${RED}ОШИБКА: Файл не найден: $PARAMS_SOURCE${NC}"
        exit 1
    fi
    cp "$PARAMS_SOURCE" "$TEMP_PARAMS"
fi

# Загружаем переменные
source "$TEMP_PARAMS"

# Проверяем обязательные переменные
for var in PORT DEST_DOMAIN PRIVATE_KEY PUBLIC_KEY SHORT_ID SSH_PORT USER_NAME; do
    if [ -z "${!var:-}" ]; then
        echo -e "${RED}ОШИБКА: В params.env отсутствует переменная $var${NC}"
        rm -f "$TEMP_PARAMS"
        exit 1
    fi
done

echo "  Порт: $PORT"
echo "  Dest: $DEST_DOMAIN"
echo "  SSH:  $SSH_PORT"
echo "  Пользователь: $USER_NAME"

# ============================================================================
# [2/8] Установка зависимостей
# ============================================================================
echo -e "${GREEN}[2/8] Установка зависимостей...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget unzip jq openssl ufw > /dev/null

# ============================================================================
# [3/8] Установка Xray-core
# ============================================================================
echo -e "${GREEN}[3/8] Установка Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

# ============================================================================
# [4/8] Восстановление конфигурации Xray
# ============================================================================
echo -e "${GREEN}[4/8] Восстановление конфигурации Xray (те же UUID)...${NC}"
mkdir -p /usr/local/etc/xray

# Считываем UUID клиентов из params.env
CLIENTS_JSON=""
CLIENT_COUNT=0
for var in $(grep "^CLIENT_.*_UUID=" "$TEMP_PARAMS" | cut -d= -f1 | sort -V); do
    UUID="${!var}"
    CLIENTS_JSON+="      {\"id\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"},"$'\n'
    CLIENT_COUNT=$((CLIENT_COUNT + 1))
done
CLIENTS_JSON=$(echo "$CLIENTS_JSON" | sed '$ s/,$//')

echo "  Восстановлено клиентов: $CLIENT_COUNT"

cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [
$CLIENTS_JSON
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$DEST_DOMAIN:443",
        "serverNames": ["$DEST_DOMAIN"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID", ""]
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"]
    }
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

# ============================================================================
# [5/8] Настройка firewall и запуск Xray
# ============================================================================
echo -e "${GREEN}[5/8] Настройка firewall и запуск Xray...${NC}"
ufw allow $SSH_PORT/tcp > /dev/null
ufw allow $PORT/tcp > /dev/null
ufw --force enable > /dev/null 2>&1

systemctl enable xray > /dev/null 2>&1
systemctl restart xray

sleep 2
if ! systemctl is-active --quiet xray; then
    echo -e "${RED}ОШИБКА: Xray не запустился. Логи:${NC}"
    journalctl -u xray --no-pager -n 20
    rm -f "$TEMP_PARAMS"
    exit 1
fi

# ============================================================================
# [6/8] Настройка SSH
# ============================================================================
echo -e "${GREEN}[6/8] Настройка SSH (порт $SSH_PORT, запрет root)...${NC}"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s) 2>/dev/null || true

sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config

grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin no" >> /etc/ssh/sshd_config
grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

systemctl restart sshd

# ============================================================================
# [7/8] Создание пользователя duplicator (новый пароль)
# ============================================================================
echo -e "${GREEN}[7/8] Создание пользователя $USER_NAME (новый пароль)...${NC}"
NEW_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)

if id "$USER_NAME" &>/dev/null; then
    echo "$USER_NAME:$NEW_PASSWORD" | chpasswd
else
    useradd -m -s /bin/bash "$USER_NAME"
    echo "$USER_NAME:$NEW_PASSWORD" | chpasswd
fi

usermod -aG sudo "$USER_NAME"
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER_NAME"
chmod 440 "/etc/sudoers.d/$USER_NAME"

# ============================================================================
# [8/8] Обновление MOTD с новыми ссылками
# ============================================================================
echo -e "${GREEN}[8/8] Обновление MOTD с новыми ссылками...${NC}"

NEW_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)
BACKUP_DIR="/root/reality-backup"
mkdir -p "$BACKUP_DIR"

# Обновляем params.env с новым IP и паролем
sed -i "s/^VPS_IP=.*/VPS_IP=$NEW_IP/" "$TEMP_PARAMS"
sed -i "s/^USER_PASSWORD=.*/USER_PASSWORD=$NEW_PASSWORD/" "$TEMP_PARAMS"
cp "$TEMP_PARAMS" "$BACKUP_DIR/params.env"
rm -f "$TEMP_PARAMS"

# Генерируем новые ссылки с новым IP
MOTD_LINKS=""
> "$BACKUP_DIR/client-links.txt"

for var in $(grep "^CLIENT_.*_UUID=" "$BACKUP_DIR/params.env" | cut -d= -f1 | sort -V); do
    UUID="${!var}"
    NUM=$(echo "$var" | sed 's/CLIENT_0*\([0-9]*\)_UUID/\1/')
    NUM=$(printf '%02d' "$NUM")
    LINK="vless://${UUID}@${NEW_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Kek-Client-${NUM}"
    MOTD_LINKS+="$LINK"$'\n'
    echo "$LINK" >> "$BACKUP_DIR/client-links.txt"
done

# Записываем MOTD
cat > /etc/motd << EOF

========================================
  VLESS Reality Proxy — (RESTORED)
========================================

  SSH:  ssh ${USER_NAME}@${NEW_IP} -p ${SSH_PORT}
  Pass: ${NEW_PASSWORD}

  Клиентские ссылки (v2rayNG / Hiddify):
$(echo "$MOTD_LINKS" | sed 's/^/  /')

  Конфиг сохранён: ${BACKUP_DIR}/params.env
========================================

EOF

# ============================================================================
# Вывод результата
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              RESTORATION COMPLETE                        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}SSH доступ:${NC}"
echo -e "  ${YELLOW}ssh ${USER_NAME}@${NEW_IP} -p ${SSH_PORT}${NC}"
echo -e "  ${YELLOW}Пароль: ${NEW_PASSWORD}${NC}"
echo ""
echo -e "${GREEN}Клиентские ссылки (UUID те же, IP новый):${NC}"
echo ""

for var in $(grep "^CLIENT_.*_UUID=" "$BACKUP_DIR/params.env" | cut -d= -f1 | sort -V); do
    UUID="${!var}"
    NUM=$(echo "$var" | sed 's/CLIENT_0*\([0-9]*\)_UUID/\1/')
    NUM=$(printf '%02d' "$NUM")
    LINK="vless://${UUID}@${NEW_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${DEST_DOMAIN}-Client-${NUM}"
    echo -e "${YELLOW}Клиент ${NUM}:${NC}"
    echo "$LINK"
    echo ""
done

echo -e "${GREEN}Готово! Можно продолжать пользоваться теми же конфигами.${NC}"
echo -e "${YELLOW}Если в конфигах был прописан IP — обновите его на ${NEW_IP}${NC}"
echo -e "${YELLOW}Если был домен — DNS обновится автоматически.${NC}"
