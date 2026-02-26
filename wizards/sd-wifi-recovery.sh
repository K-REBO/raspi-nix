#!/usr/bin/env bash
set -e

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}================================================${NC}"
echo -e "${BOLD}   NixOS SD カード WiFi 復旧ウィザード${NC}"
echo -e "${BOLD}================================================${NC}"
echo ""

# root 権限チェック
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ sudo が必要です${NC}"
  echo "   sudo bash $0"
  exit 1
fi

cleanup() {
  if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    echo ""
    echo -e "${YELLOW}⚠️  クリーンアップ: アンマウント中...${NC}"
    umount "$MOUNT_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

MOUNT_DIR="/tmp/nixos-sd-mount"

# ─────────────────────────────────────────
# STEP 1: SD カードの選択
# ─────────────────────────────────────────
echo -e "${BLUE}${BOLD}STEP 1: SD カードを選択${NC}"
echo ""
echo "接続されているブロックデバイス:"
echo ""
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "loop"
echo ""

read -rp "SD カードのデバイス名を入力 (例: sdb, mmcblk0): " SD_INPUT
SD_DEV="/dev/${SD_INPUT#/dev/}"

if [ ! -b "$SD_DEV" ]; then
  echo -e "${RED}❌ デバイス $SD_DEV が見つかりません${NC}"
  exit 1
fi

echo ""
echo -e "パーティション構成:"
lsblk "$SD_DEV"
echo ""

# パーティション名を決定 (mmcblk0 → mmcblk0p2, sdb → sdb2)
if [[ "$SD_DEV" == *"mmcblk"* ]] || [[ "$SD_DEV" == *"nvme"* ]]; then
  ROOT_PART="${SD_DEV}p2"
else
  ROOT_PART="${SD_DEV}2"
fi

echo -e "ルートパーティション: ${BOLD}$ROOT_PART${NC}"
read -rp "正しいですか? (Y/n): " confirm
if [[ "$confirm" =~ ^[nN]$ ]]; then
  read -rp "正しいパーティションを入力 (例: /dev/sdb2): " ROOT_PART
fi

# ─────────────────────────────────────────
# STEP 2: マウント
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}STEP 2: SD カードをマウント${NC}"
echo ""

mkdir -p "$MOUNT_DIR"
mount "$ROOT_PART" "$MOUNT_DIR"
echo -e "${GREEN}✅ マウント完了: $MOUNT_DIR${NC}"

# NixOS かどうか確認
if [ ! -d "$MOUNT_DIR/nix/store" ]; then
  echo -e "${RED}❌ NixOS パーティションではないようです${NC}"
  exit 1
fi
echo -e "${GREEN}✅ NixOS パーティションを確認${NC}"

# ─────────────────────────────────────────
# STEP 3: WiFi 情報の入力
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}STEP 3: WiFi 設定を入力${NC}"
echo ""

read -rp "WiFi SSID (ネットワーク名): " WIFI_SSID
read -rsp "WiFi パスワード: " WIFI_PASS
echo ""

# PSK を生成 (wpa_passphrase が使えれば使う)
if command -v wpa_passphrase &>/dev/null; then
  WPA_BLOCK=$(wpa_passphrase "$WIFI_SSID" "$WIFI_PASS")
  # psk= の行 (コメントなし) を取得
  WPA_PSK_LINE=$(echo "$WPA_BLOCK" | grep -v "#" | grep "psk=")
else
  WPA_PSK_LINE="psk=\"$WIFI_PASS\""
fi

# ─────────────────────────────────────────
# STEP 4: wpa_supplicant.conf を作成
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}STEP 4: wpa_supplicant.conf を設定${NC}"
echo ""

WPA_CONF="$MOUNT_DIR/etc/wpa_supplicant.conf"

# シンボリックリンクの場合は削除して実ファイルを作成
if [ -L "$WPA_CONF" ]; then
  echo -e "${YELLOW}  ⚠️  シンボリックリンクを削除して実ファイルを作成${NC}"
  rm "$WPA_CONF"
fi

cat > "$WPA_CONF" << EOF
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=wheel
update_config=1

network={
    ssid="$WIFI_SSID"
    $WPA_PSK_LINE
}
EOF

echo -e "${GREEN}✅ wpa_supplicant.conf を作成しました${NC}"

# ─────────────────────────────────────────
# STEP 5: systemd サービスを有効化
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}STEP 5: wpa_supplicant サービスを設定${NC}"
echo ""

SYSTEMD_DIR="$MOUNT_DIR/etc/systemd/system"
WANTS_DIR="$SYSTEMD_DIR/network-online.target.wants"
mkdir -p "$WANTS_DIR"

# カスタム wpa_supplicant サービスを作成
cat > "$SYSTEMD_DIR/wpa_supplicant-recovery.service" << 'EOF'
[Unit]
Description=WPA supplicant (WiFi recovery mode)
Before=network.target
After=dbus.service

[Service]
Type=forking
PIDFile=/run/wpa_supplicant/wlan0.pid
ExecStart=/run/current-system/sw/bin/wpa_supplicant \
  -B \
  -i wlan0 \
  -c /etc/wpa_supplicant.conf \
  -P /run/wpa_supplicant/wlan0.pid
ExecStartPost=/bin/sh -c 'sleep 3 && /run/current-system/sw/bin/dhcpcd wlan0 || true'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# multi-user.target.wants に登録
ln -sf "../wpa_supplicant-recovery.service" \
  "$SYSTEMD_DIR/multi-user.target.wants/wpa_supplicant-recovery.service"

echo -e "${GREEN}✅ systemd サービスを登録しました${NC}"

# ─────────────────────────────────────────
# STEP 6: アンマウント
# ─────────────────────────────────────────
echo ""
echo -e "${BLUE}${BOLD}STEP 6: SD カードをアンマウント${NC}"
echo ""

sync
umount "$MOUNT_DIR"
# trap の cleanup が二重実行されないよう MOUNT_DIR を空にする
MOUNT_DIR=""

echo -e "${GREEN}✅ アンマウント完了${NC}"

# ─────────────────────────────────────────
# 完了
# ─────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}🎉 完了!${NC}"
echo ""
echo -e "${BOLD}次の手順:${NC}"
echo "  1. SD カードを Raspberry Pi に挿入"
echo "  2. 電源を入れる"
echo "  3. 2〜3分待つ"
echo "  4. SSH 接続を試す:"
echo "       ssh rpi@nixpi"
echo "     または Tailscale IP:"
echo "       ssh rpi@100.110.102.45"
echo ""
echo -e "${YELLOW}⚠️  接続後にやること:${NC}"
echo "  configuration.nix に WiFi 設定を追加して再デプロイする"
echo "  (このウィザードの設定は次回 nixos-rebuild で上書きされます)"
echo ""
