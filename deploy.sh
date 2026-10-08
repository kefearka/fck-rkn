#!/bin/bash
# ============================================================================
# VLESS + Reality + TCP 
# Запуск: bash deploy.sh [PORT] [DEST_DOMAIN] [CLIENTS_COUNT]
# Пример: bash deploy.sh 443 dl.google.com 10
# ============================================================================
set -euo pipefail

# Параметры
PORT="${1:-443}"
DEST_DOMAIN="${2:-dl.google.com}"
CLIENTS_COUNT="${3:-10}"
SSH_PORT="3452"
USER_NAME="duplicator"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ОШИБКА: Скрипт должен быть запущен от root${NC}"
    exit 1
fi

echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   VLESS Reality TCP — Deployment                           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# [1/8] Установка зависимостей
# ============================================================================
echo -e "${GREEN}[1/8] Установка зависимостей...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget unzip jq openssl ufw > /dev/null

# ============================================================================
# [2/8] Установка Xray-core
# ============================================================================
echo -e "${GREEN}[2/8] Установка Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

# ============================================================================
# [3/8] Генерация ключей и UUID
# ============================================================================
echo -e "${GREEN}[3/8] Генерация ключей Reality и UUID клиентов...${NC}"
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# Генерируем UUID для каждого клиента
declare -a CLIENT_UUIDS
for i in $(seq 1 $CLIENTS_COUNT); do
    UUID=$(xray uuid)
    CLIENT_UUIDS+=("$UUID")
    echo -e "  ${YELLOW}Клиент $(printf '%02d' $i):${NC} $UUID"
done

# ============================================================================
# [4/8] Создание конфигурации Xray
# ============================================================================
echo -e "${GREEN}[4/8] Создание конфигурации Xray...${NC}"
mkdir -p /usr/local/etc/xray

# Формируем массив клиентов для JSON
CLIENTS_JSON=""
for UUID in "${CLIENT_UUIDS[@]}"; do
    CLIENTS_JSON+="      {\"id\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"},"$'\n'
done
CLIENTS_JSON=$(echo "$CLIENTS_JSON" | sed '$ s/,$//')

cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
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
          "serverNames": [
            "$DEST_DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID",
            ""
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
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
    exit 1
fi

# ============================================================================
# [6/8] Настройка SSH
# ============================================================================
echo -e "${GREEN}[6/8] Настройка SSH (порт $SSH_PORT, запрет root)...${NC}"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

# Применяем настройки SSH
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config

# Если строки не существовали, добавляем
grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin no" >> /etc/ssh/sshd_config
grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

systemctl restart sshd

# ============================================================================
# [7/8] Создание пользователя duplicator
# ============================================================================
echo -e "${GREEN}[7/8] Создание пользователя $USER_NAME...${NC}"
USER_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)

if id "$USER_NAME" &>/dev/null; then
    echo -e "  ${YELLOW}Пользователь $USER_NAME уже существует, обновляем пароль${NC}"
    echo "$USER_NAME:$USER_PASSWORD" | chpasswd
else
    useradd -m -s /bin/bash "$USER_NAME"
    echo "$USER_NAME:$USER_PASSWORD" | chpasswd
fi

# Добавляем в группу sudo (root-права)
usermod -aG sudo "$USER_NAME"

# Настраиваем sudo без пароля для удобства
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER_NAME"
chmod 440 "/etc/sudoers.d/$USER_NAME"

# ============================================================================
# [8/8] MOTD и сохранение параметров
# ============================================================================
echo -e "${GREEN}[8/8] Настройка MOTD и сохранение параметров...${NC}"

VPS_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)
BACKUP_DIR="/root/reality-backup"
mkdir -p "$BACKUP_DIR"

# Сохраняем параметры
cat > "$BACKUP_DIR/params.env" << EOF
PORT=$PORT
DEST_DOMAIN=$DEST_DOMAIN
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
VPS_IP=$VPS_IP
SSH_PORT=$SSH_PORT
USER_NAME=$USER_NAME
USER_PASSWORD=$USER_PASSWORD
EOF

for i in "${!CLIENT_UUIDS[@]}"; do
    echo "CLIENT_$((i+1))_UUID=${CLIENT_UUIDS[$i]}" >> "$BACKUP_DIR/params.env"
done

cp /usr/local/etc/xray/config.json "$BACKUP_DIR/config.json"

# Генерируем ссылки для MOTD
MOTD_LINKS=""
for i in "${!CLIENT_UUIDS[@]}"; do
    UUID="${CLIENT_UUIDS[$i]}"
    NUM=$(printf '%02d' $((i+1)))
    LINK="vless://${UUID}@${VPS_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Kek-Client-${NUM}"
    MOTD_LINKS+="$LINK"$'\n'
    echo "$LINK" >> "$BACKUP_DIR/client-links.txt"
done

# Записываем MOTD
cat > /etc/motd << EOF

========================================
  VLESS Reality Proxy
========================================

  SSH:  ssh ${USER_NAME}@${VPS_IP} -p ${SSH_PORT}
  Pass: ${USER_PASSWORD}

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
echo -e "${CYAN}║              DEPLOYMENT COMPLETE                         ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}SSH доступ:${NC}"
echo -e "  ${YELLOW}ssh ${USER_NAME}@${VPS_IP} -p ${SSH_PORT}${NC}"
echo -e "  ${YELLOW}Пароль: ${USER_PASSWORD}${NC}"
echo ""
echo -e "${GREEN}Клиентские ссылки (скопируйте в v2rayNG / Hiddify):${NC}"
echo ""
for i in "${!CLIENT_UUIDS[@]}"; do
    UUID="${CLIENT_UUIDS[$i]}"
    NUM=$(printf '%02d' $((i+1)))
    LINK="vless://${UUID}@${VPS_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${DEST_DOMAIN}-Client-${NUM}"
    echo -e "${YELLOW}Клиент ${NUM}:${NC}"
    echo "$LINK"
    echo ""
done

echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  КРИТИЧНО: Скопируйте файл params.env к себе локально!   ║${NC}"
echo -e "${RED}║  Путь: ${BACKUP_DIR}/params.env                         ║${NC}"
echo -e "${RED}║  Команда: scp root@${VPS_IP}:${BACKUP_DIR}/params.env ./  ║${NC}"
echo -e "${RED}║  Без этого файла восстановление невозможно!              ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Теперь можно выйти и зайти под пользователем ${USER_NAME}:${NC}"
echo -e "  ${YELLOW}ssh ${USER_NAME}@${VPS_IP} -p ${SSH_PORT}${NC}"
