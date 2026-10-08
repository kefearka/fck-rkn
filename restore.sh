#!/bin/bash
# ============================================================================
# VLESS + Reality + TCP — Restoration on new VPS
# Usage: bash restore.sh <path_to_params.env_or_URL>
# Example: bash restore.sh ./params.env
#          bash restore.sh https://example.com/params.env
# ============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check argument
if [ $# -lt 1 ]; then
    echo -e "${RED}Usage: bash restore.sh <path_to_params.env_or_URL>${NC}"
    exit 1
fi

PARAMS_SOURCE="$1"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Script must be run as root${NC}"
    exit 1
fi

echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   VLESS Reality TCP — Restoration                        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Load parameters
# ============================================================================
echo -e "${GREEN}[1/8] Loading parameters...${NC}"
TEMP_PARAMS="/tmp/params.env.$$"

if [[ "$PARAMS_SOURCE" =~ ^https?:// ]]; then
    echo "  Downloading from URL: $PARAMS_SOURCE"
    curl -sSL "$PARAMS_SOURCE" -o "$TEMP_PARAMS"
else
    if [ ! -f "$PARAMS_SOURCE" ]; then
        echo -e "${RED}ERROR: File not found: $PARAMS_SOURCE${NC}"
        exit 1
    fi
    cp "$PARAMS_SOURCE" "$TEMP_PARAMS"
fi

# Load variables
source "$TEMP_PARAMS"

# Check required variables
for var in PORT DEST_DOMAIN PRIVATE_KEY PUBLIC_KEY SHORT_ID SSH_PORT USER_NAME; do
    if [ -z "${!var:-}" ]; then
        echo -e "${RED}ERROR: Missing variable $var in params.env${NC}"
        rm -f "$TEMP_PARAMS"
        exit 1
    fi
done

echo "  Port: $PORT"
echo "  Dest: $DEST_DOMAIN"
echo "  SSH:  $SSH_PORT"
echo "  User: $USER_NAME"

# ============================================================================
# [2/8] Install dependencies
# ============================================================================
echo -e "${GREEN}[2/8] Installing dependencies...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget unzip jq openssl ufw > /dev/null

# ============================================================================
# [3/8] Install Xray-core
# ============================================================================
echo -e "${GREEN}[3/8] Installing Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

# ============================================================================
# [4/8] Restore Xray configuration
# ============================================================================
echo -e "${GREEN}[4/8] Restoring Xray configuration (same UUIDs)...${NC}"
mkdir -p /usr/local/etc/xray

# Read client UUIDs from params.env
CLIENTS_JSON=""
CLIENT_COUNT=0
UUIDS_ARRAY=()
for var in $(grep "^CLIENT_.*_UUID=" "$TEMP_PARAMS" | cut -d= -f1 | sort -V); do
    UUIDS_ARRAY+=("${!var}")
    CLIENT_COUNT=$((CLIENT_COUNT + 1))
done
LAST_INDEX=$((${#UUIDS_ARRAY[@]} - 1))
for i in "${!UUIDS_ARRAY[@]}"; do
    UUID="${UUIDS_ARRAY[$i]}"
    if [ "$i" -lt "$LAST_INDEX" ]; then
        CLIENTS_JSON+="      {\"id\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"},"$'\n'
    else
        CLIENTS_JSON+="      {\"id\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"}"$'\n'
    fi
done

echo "  Restored clients: $CLIENT_COUNT"

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
# [5/8] Configure firewall and start Xray
# ============================================================================
echo -e "${GREEN}[5/8] Configuring firewall and starting Xray...${NC}"
ufw allow $SSH_PORT/tcp > /dev/null
ufw allow $PORT/tcp > /dev/null
ufw --force enable > /dev/null 2>&1

systemctl enable xray > /dev/null 2>&1
systemctl restart xray

sleep 2
if ! systemctl is-active --quiet xray; then
    echo -e "${RED}ERROR: Xray failed to start. Logs:${NC}"
    journalctl -u xray --no-pager -n 20
    rm -f "$TEMP_PARAMS"
    exit 1
fi

# ============================================================================
# [6/8] Configure SSH
# ============================================================================
echo -e "${GREEN}[6/8] Configuring SSH (port $SSH_PORT, disable root)...${NC}"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s) 2>/dev/null || true

sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config

grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin no" >> /etc/ssh/sshd_config
grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

systemctl restart sshd

# ============================================================================
# [7/8] Create user duplicator (new password)
# ============================================================================
echo -e "${GREEN}[7/8] Creating user $USER_NAME (new password)...${NC}"
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
# [8/8] Update MOTD with new links
# ============================================================================
echo -e "${GREEN}[8/8] Updating MOTD with new links...${NC}"

NEW_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)
BACKUP_DIR="/root/reality-backup"
mkdir -p "$BACKUP_DIR"

# Update params.env with new IP and password
sed -i "s/^VPS_IP=.*/VPS_IP=$NEW_IP/" "$TEMP_PARAMS"
sed -i "s/^USER_PASSWORD=.*/USER_PASSWORD=$NEW_PASSWORD/" "$TEMP_PARAMS"
cp "$TEMP_PARAMS" "$BACKUP_DIR/params.env"
rm -f "$TEMP_PARAMS"

# Generate new links with new IP
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

# Write MOTD
cat > /etc/motd << EOF

========================================
  VLESS Reality Proxy — (RESTORED)
========================================

  SSH:  ssh ${USER_NAME}@${NEW_IP} -p ${SSH_PORT}
  Pass: ${NEW_PASSWORD}

  Client links (v2rayNG / Hiddify):
$(echo "$MOTD_LINKS" | sed 's/^/  /')

  Config saved: ${BACKUP_DIR}/params.env
========================================

EOF

# ============================================================================
# Output result
# ============================================================================
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              RESTORATION COMPLETE                        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}SSH access:${NC}"
echo -e "  ${YELLOW}ssh ${USER_NAME}@${NEW_IP} -p ${SSH_PORT}${NC}"
echo -e "  ${YELLOW}Password: ${NEW_PASSWORD}${NC}"
echo ""
echo -e "${GREEN}Client links (same UUIDs, new IP):${NC}"
echo ""

for var in $(grep "^CLIENT_.*_UUID=" "$BACKUP_DIR/params.env" | cut -d= -f1 | sort -V); do
    UUID="${!var}"
    NUM=$(echo "$var" | sed 's/CLIENT_0*\([0-9]*\)_UUID/\1/')
    NUM=$(printf '%02d' "$NUM")
    LINK="vless://${UUID}@${NEW_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${DEST_DOMAIN}-Client-${NUM}"
    echo -e "${YELLOW}Client ${NUM}:${NC}"
    echo "$LINK"
    echo ""
done

echo -e "${GREEN}Done! Now continue using the same configs.${NC}"
echo -e "${YELLOW}If configs had IP address — update it to ${NEW_IP}${NC}"
echo -e "${YELLOW}If configs had domain name — DNS will update automatically.${NC}"
