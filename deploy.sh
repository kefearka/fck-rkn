#!/bin/bash
# ============================================================================
# VLESS + Reality + TCP — Quick Deployment
# Usage: bash deploy.sh [PORT] [DEST_DOMAIN] [CLIENTS_COUNT]
# Example: bash deploy.sh 443 dl.google.com 10
# ============================================================================
set -euo pipefail

# Parameters
PORT="${1:-443}"
DEST_DOMAIN="${2:-dl.google.com}"
CLIENTS_COUNT="${3:-10}"
SSH_PORT="3452"
USER_NAME="duplicator"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Script must be run as root${NC}"
    exit 1
fi

echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   VLESS Reality TCP — Deployment                           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# [1/8] Install dependencies
# ============================================================================
echo -e "${GREEN}[1/8] Installing dependencies...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget unzip jq openssl ufw > /dev/null

# ============================================================================
# [2/8] Install Xray-core
# ============================================================================
echo -e "${GREEN}[2/8] Installing Xray-core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

# ============================================================================
# [3/8] Generate keys and UUIDs
# ============================================================================
echo -e "${GREEN}[3/8] Generating Reality keys and client UUIDs...${NC}"
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# Generate UUID for each client
declare -a CLIENT_UUIDS
for i in $(seq 1 $CLIENTS_COUNT); do
    UUID=$(xray uuid)
    CLIENT_UUIDS+=("$UUID")
    echo -e "  ${YELLOW}Client $(printf '%02d' $i):${NC} $UUID"
done

# ============================================================================
# [4/8] Create Xray configuration
# ============================================================================
echo -e "${GREEN}[4/8] Creating Xray configuration...${NC}"
mkdir -p /usr/local/etc/xray

# Build clients array for JSON
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
    exit 1
fi

# ============================================================================
# [6/8] Configure SSH
# ============================================================================
echo -e "${GREEN}[6/8] Configuring SSH (port $SSH_PORT, disable root)...${NC}"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

# Apply SSH settings
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config

# Add lines if they don't exist
grep -q "^Port " /etc/ssh/sshd_config || echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
grep -q "^PermitRootLogin " /etc/ssh/sshd_config || echo "PermitRootLogin no" >> /etc/ssh/sshd_config
grep -q "^PasswordAuthentication " /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

systemctl restart sshd

# ============================================================================
# [7/8] Create user duplicator
# ============================================================================
echo -e "${GREEN}[7/8] Creating user $USER_NAME...${NC}"
USER_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)

if id "$USER_NAME" &>/dev/null; then
    echo -e "  ${YELLOW}User $USER_NAME already exists, updating password${NC}"
    echo "$USER_NAME:$USER_PASSWORD" | chpasswd
else
    useradd -m -s /bin/bash "$USER_NAME"
    echo "$USER_NAME:$USER_PASSWORD" | chpasswd
fi

# Add to sudo group (root privileges)
usermod -aG sudo "$USER_NAME"

# Configure passwordless sudo for convenience
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER_NAME"
chmod 440 "/etc/sudoers.d/$USER_NAME"

# ============================================================================
# [8/8] MOTD and save parameters
# ============================================================================
echo -e "${GREEN}[8/8] Setting up MOTD and saving parameters...${NC}"

VPS_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb)
BACKUP_DIR="/root/reality-backup"
mkdir -p "$BACKUP_DIR"

# Save parameters
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

# Generate links for MOTD
MOTD_LINKS=""
for i in "${!CLIENT_UUIDS[@]}"; do
    UUID="${CLIENT_UUIDS[$i]}"
    NUM=$(printf '%02d' $((i+1)))
    LINK="vless://${UUID}@${VPS_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Kek-Client-${NUM}"
    MOTD_LINKS+="$LINK"$'\n'
    echo "$LINK" >> "$BACKUP_DIR/client-links.txt"
done

# Write MOTD
cat > /etc/motd << EOF

========================================
  VLESS Reality Proxy
========================================

  SSH:  ssh ${USER_NAME}@${VPS_IP} -p ${SSH_PORT}
  Pass: ${USER_PASSWORD}

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
echo -e "${CYAN}║              DEPLOYMENT COMPLETE                         ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}SSH access:${NC}"
echo -e "  ${YELLOW}ssh ${USER_NAME}@${VPS_IP} -p ${SSH_PORT}${NC}"
echo -e "  ${YELLOW}Password: ${USER_PASSWORD}${NC}"
echo ""
echo -e "${GREEN}Client links (copy to v2rayNG / Hiddify):${NC}"
echo ""
for i in "${!CLIENT_UUIDS[@]}"; do
    UUID="${CLIENT_UUIDS[$i]}"
    NUM=$(printf '%02d' $((i+1)))
    LINK="vless://${UUID}@${VPS_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${DEST_DOMAIN}-Client-${NUM}"
    echo -e "${YELLOW}Client ${NUM}:${NC}"
    echo "$LINK"
    echo ""
done

echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  CRITICAL: Copy params.env file to your local machine!   ║${NC}"
echo -e "${RED}║  Path: ${BACKUP_DIR}/params.env                         ║${NC}"
echo -e "${RED}║  Command: scp root@${VPS_IP}:${BACKUP_DIR}/params.env ./  ║${NC}"
echo -e "${RED}║  Without this file, restoration is impossible!           ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}You can now logout and login as user ${USER_NAME}:${NC}"
echo -e "  ${YELLOW}ssh ${USER_NAME}@${VPS_IP} -p ${SSH_PORT}${NC}"
