#!/usr/bin/env bash
set -e

# ── カラー & スタイル ──────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[38;5;203m'
GREEN='\033[38;5;114m'
YELLOW='\033[38;5;221m'
BLUE='\033[38;5;75m'
CYAN='\033[38;5;80m'
MAGENTA='\033[38;5;177m'
GRAY='\033[38;5;245m'

TOTAL_STEPS=7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── ユーティリティ ────────────────────────────────────────

# ステップヘッダー
step() {
  local n=$1 title=$2
  local filled=$(( n - 1 ))
  local empty=$(( TOTAL_STEPS - n ))
  echo ""
  # ステップドット
  local dots=""
  for ((i=1; i<=TOTAL_STEPS; i++)); do
    if   (( i < n  )); then dots+="${GREEN}●${RESET}${GRAY}─${RESET}"
    elif (( i == n )); then dots+="${CYAN}${BOLD}◉${RESET}${GRAY}─${RESET}"
    else                    dots+="${GRAY}○─${RESET}"
    fi
  done
  echo -e "  ${dots%?}"   # 末尾の ─ を除去
  echo -e "  ${CYAN}${BOLD}[ $n / $TOTAL_STEPS ]  $title${RESET}"
  echo -e "  ${GRAY}$(printf '%.0s─' {1..48})${RESET}"
  echo ""
}

ok()   { echo -e "  ${GREEN}✓${RESET}  $*"; }
info() { echo -e "  ${BLUE}›${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}!${RESET}  $*"; }
err()  { echo -e "  ${RED}✗${RESET}  $*"; }
ask()  { echo -en "  ${MAGENTA}?${RESET}  $*"; }

# スピナー (バックグラウンド PID を渡す)
spinner_start() {
  local msg=$1
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local i=0
  while true; do
    echo -en "\r  ${CYAN}${frames[$i]}${RESET}  $msg"
    i=$(( (i+1) % ${#frames[@]} ))
    sleep 0.08
  done &
  SPINNER_PID=$!
}
spinner_stop() {
  kill "$SPINNER_PID" 2>/dev/null
  wait "$SPINNER_PID" 2>/dev/null || true
  echo -en "\r\033[2K"
}

# ── ヘッダー ─────────────────────────────────────────────
clear
echo ""
echo -e "  ${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "  ${CYAN}${BOLD}║${RESET}                                                  ${CYAN}${BOLD}║${RESET}"
echo -e "  ${CYAN}${BOLD}║${RESET}   ${BOLD}NixOS  ×  Raspberry Pi${RESET}                        ${CYAN}${BOLD}║${RESET}"
echo -e "  ${CYAN}${BOLD}║${RESET}   ${GRAY}SD カード ビルド & 書き込みウィザード${RESET}          ${CYAN}${BOLD}║${RESET}"
echo -e "  ${CYAN}${BOLD}║${RESET}                                                  ${CYAN}${BOLD}║${RESET}"
echo -e "  ${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${YELLOW}!${RESET}  SD カードは ${BOLD}STEP 5${RESET} で挿入してください"
echo -e "     先に挿すとデバイス名が変わり、誤検出の原因になります"
echo ""
ask "準備ができたら Enter を押してください..."
read -r
echo ""

# ══════════════════════════════════════════════════
# STEP 1: WiFi 設定
# ══════════════════════════════════════════════════
step 1 "WiFi 設定"

LOCAL_NIX="$PROJECT_DIR/configuration.local.nix"

ask "有線 LAN で使用するため WiFi 設定をスキップしますか? [y/N]: "
read -r skip_wifi
if [[ "$skip_wifi" =~ ^[yY]$ ]]; then
  info "WiFi 設定をスキップします"
  SKIP_WIFI=true
elif [ -f "$LOCAL_NIX" ]; then
  info "既存の設定が見つかりました: ${BOLD}configuration.local.nix${RESET}"
  echo ""
  echo -e "${GRAY}"
  sed 's/^/     /' "$LOCAL_NIX"
  echo -e "${RESET}"
  ask "WiFi 設定を上書きしますか? [y/N]: "
  read -r overwrite
  if [[ ! "$overwrite" =~ ^[yY]$ ]]; then
    info "既存の設定を使用します"
    SKIP_WIFI=true
  fi
fi

if [ "${SKIP_WIFI:-false}" = "false" ]; then
  ask "SSID (ネットワーク名): "
  read -r WIFI_SSID
  ask "パスワード: "
  read -rs WIFI_PASS
  echo ""

  cat > "$LOCAL_NIX" << EOF
# ローカルWiFi設定 (.gitignore に含まれています)
{ ... }: {
  networking.wireless = {
    enable = true;
    networks = {
      "${WIFI_SSID}" = {
        psk = "${WIFI_PASS}";
      };
    };
  };
}
EOF
  ok "configuration.local.nix を作成しました"
fi

# ══════════════════════════════════════════════════
# STEP 2: SSH 公開鍵の登録
# ══════════════════════════════════════════════════
step 2 "SSH 公開鍵の登録"

info "現在 configuration.nix に登録されている公開鍵:"
echo ""
grep -A2 "authorizedKeys.keys" "$PROJECT_DIR/configuration.nix" \
  | grep "ssh-" \
  | sed "s/^/     ${GRAY}/" \
  | sed "s/$/${RESET}/"
echo ""

ask "登録する公開鍵ファイルのパス (空 Enter でスキップ): "
read -r PUBKEY_PATH

if [ -z "$PUBKEY_PATH" ]; then
  info "スキップします"
elif [ ! -f "$PUBKEY_PATH" ]; then
  err "ファイルが見つかりません: $PUBKEY_PATH"
  info "スキップします"
else
  SELECTED_KEY=$(cat "$PUBKEY_PATH")
  if grep -qF "$SELECTED_KEY" "$PROJECT_DIR/configuration.nix"; then
    ok "この公開鍵はすでに登録されています"
  else
    sed -i "/openssh\.authorizedKeys\.keys = \[/,/\];/{
      /\];/i\\      \"${SELECTED_KEY}\"
    }" "$PROJECT_DIR/configuration.nix"
    ok "公開鍵を configuration.nix に追加しました"
  fi
fi

# ══════════════════════════════════════════════════
# STEP 3: configuration.nix の確認
# ══════════════════════════════════════════════════
step 3 "configuration.nix の確認"

CONFIG_NIX="$PROJECT_DIR/configuration.nix"

if grep -q "configuration.local.nix" "$CONFIG_NIX"; then
  ok "configuration.local.nix はすでに import されています"
else
  warn "configuration.local.nix を import に追加します"
  sed -i 's|imports = \[|imports = [\n    (if builtins.pathExists ./configuration.local.nix then ./configuration.local.nix else {})|' "$CONFIG_NIX"
  ok "imports に追加しました"
fi

# ══════════════════════════════════════════════════
# STEP 4: SD イメージをビルド
# ══════════════════════════════════════════════════
step 4 "SD イメージをビルド"

cd "$PROJECT_DIR"

spinner_start "ビルド中... (初回は数分かかります)"
nix build .#sdImage &>/tmp/nixos-sd-build.log &
NIX_PID=$!
wait $NIX_PID && BUILD_OK=true || BUILD_OK=false
spinner_stop

if [ "$BUILD_OK" = "false" ]; then
  err "ビルドに失敗しました"
  echo ""
  tail -20 /tmp/nixos-sd-build.log | sed 's/^/     /'
  exit 1
fi

SD_IMAGE=$(ls result/sd-image/*.img.zst 2>/dev/null || ls result/sd-image/*.img 2>/dev/null | head -1)
if [ -z "$SD_IMAGE" ]; then
  err "SD イメージが見つかりません"
  exit 1
fi

ok "ビルド完了"
info "イメージ: ${BOLD}$SD_IMAGE${RESET}"
info "サイズ:   $(du -h "$SD_IMAGE" | cut -f1)"

# ══════════════════════════════════════════════════
# STEP 5: SD カードを選択
# ══════════════════════════════════════════════════
step 5 "SD カードを選択"

echo -e "  ${RED}${BOLD}  SD カードをここで挿入してください  ${RESET}"
echo ""
ask "挿入したら Enter を押してください..."
read -r
echo ""

echo -e "${GRAY}"
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "loop" | sed 's/^/     /'
echo -e "${RESET}"

ask "SD カードのデバイス名 (例: sdb, mmcblk0): "
read -r SD_INPUT
SD_DEV="/dev/${SD_INPUT#/dev/}"

if [ ! -b "$SD_DEV" ]; then
  err "デバイス $SD_DEV が見つかりません"
  exit 1
fi

echo ""
info "選択されたデバイス: ${BOLD}$SD_DEV${RESET}"
echo ""
echo -e "${GRAY}"
lsblk "$SD_DEV" | sed 's/^/     /'
echo -e "${RESET}"

SD_SIZE=$(lsblk -d -o SIZE "$SD_DEV" | tail -1 | tr -d ' ')
echo -e "  ${RED}${BOLD}  ⚠  $SD_DEV ($SD_SIZE) の全データが消去されます  ${RESET}"
echo ""
ask "確認のためデバイス名を再入力: "
read -r confirm_dev

if [ "$confirm_dev" != "$SD_INPUT" ] && [ "$confirm_dev" != "$SD_DEV" ]; then
  err "キャンセルしました"
  exit 1
fi

# ══════════════════════════════════════════════════
# STEP 6: 書き込み
# ══════════════════════════════════════════════════
step 6 "SD カードに書き込み"

# マウント済みパーティションをアンマウント
for part in $(lsblk -lno NAME "$SD_DEV" | tail -n +2); do
  if mountpoint -q "/dev/$part" 2>/dev/null; then
    info "アンマウント中: /dev/$part"
    sudo umount "/dev/$part" || true
  fi
done

info "書き込みを開始します..."
echo ""

if [[ "$SD_IMAGE" == *.zst ]]; then
  if command -v pv &>/dev/null; then
    zstd -d --stdout "$SD_IMAGE" | pv | sudo dd of="$SD_DEV" bs=4M conv=fsync
  else
    zstd -d --stdout "$SD_IMAGE" | sudo dd of="$SD_DEV" bs=4M conv=fsync status=progress
  fi
else
  if command -v pv &>/dev/null; then
    pv "$SD_IMAGE" | sudo dd of="$SD_DEV" bs=4M conv=fsync
  else
    sudo dd if="$SD_IMAGE" of="$SD_DEV" bs=4M conv=fsync status=progress
  fi
fi

sync
echo ""
ok "書き込み完了!"

# ext4 64bit フィーチャーを無効化 (U-Boot との互換性)
# NixOS が生成する ext4 はデフォルトで 64bit が有効になっており
# Raspberry Pi の U-Boot がカーネルを読めなくなるため無効化する
if [[ "$SD_DEV" == *"mmcblk"* ]] || [[ "$SD_DEV" == *"nvme"* ]]; then
  ROOT_PART="${SD_DEV}p2"
else
  ROOT_PART="${SD_DEV}2"
fi

echo ""
spinner_start "ext4 64bit フィーチャーを無効化中 (U-Boot 互換性修正)..."
sudo e2fsck -fy "$ROOT_PART" &>/tmp/e2fsck.log || true
sudo resize2fs -s "$ROOT_PART" &>/tmp/resize2fs.log || true
sudo e2fsck -fy "$ROOT_PART" &>/tmp/e2fsck2.log || true
spinner_stop
ok "U-Boot 互換性修正完了"

# ══════════════════════════════════════════════════
# STEP 7: known_hosts の更新
# ══════════════════════════════════════════════════
step 7 "known_hosts の更新"

info "SD カードを Raspberry Pi に挿入して電源を入れてください"
info "起動が完了したら Enter を押してください ${GRAY}(目安: 2〜3分)${RESET}"
echo ""
ask "準備ができたら Enter を押してください..."
read -r
echo ""

ask "接続先ホスト名または IP [nixpi]: "
read -r TARGET_HOST
TARGET_HOST="${TARGET_HOST:-nixpi}"

# 古いエントリを削除
spinner_start "古いエントリを削除中..."
ssh-keygen -R "$TARGET_HOST" &>/dev/null || true
TAILSCALE_IP=$(tailscale status 2>/dev/null | awk '/nixpi/ {print $1}')
[ -n "$TAILSCALE_IP" ] && ssh-keygen -R "$TAILSCALE_IP" &>/dev/null || true
spinner_stop
ok "古いエントリを削除しました"

# 新しいホストキーを追加
spinner_start "$TARGET_HOST のホストキーを取得中..."
if ssh-keyscan -T 15 "$TARGET_HOST" >> ~/.ssh/known_hosts 2>/dev/null; then
  spinner_stop
  ok "$TARGET_HOST のホストキーを追加しました"
else
  spinner_stop
  err "ホストキーの取得に失敗しました。手動で実行してください:"
  echo ""
  echo -e "     ${GRAY}ssh-keygen -R $TARGET_HOST${RESET}"
  echo -e "     ${GRAY}ssh-keyscan $TARGET_HOST >> ~/.ssh/known_hosts${RESET}"
fi

# Tailscale IP も追加
if [ -n "$TAILSCALE_IP" ]; then
  spinner_start "Tailscale ($TAILSCALE_IP) のホストキーを取得中..."
  if ssh-keyscan -T 10 "$TAILSCALE_IP" >> ~/.ssh/known_hosts 2>/dev/null; then
    spinner_stop
    ok "Tailscale ($TAILSCALE_IP) のホストキーを追加しました"
  else
    spinner_stop
    warn "Tailscale 経由はまだオンラインでない可能性があります"
  fi
fi

# SSH 接続テスト
echo ""
spinner_start "SSH 接続テスト中..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes rpi@"$TARGET_HOST" "echo ok" &>/dev/null; then
  spinner_stop
  ok "SSH 接続成功!"
else
  spinner_stop
  warn "接続できませんでした。少し待ってから試してください"
fi

# ══════════════════════════════════════════════════
# 完了
# ══════════════════════════════════════════════════
echo ""
echo -e "  ${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "  ${GREEN}${BOLD}║${RESET}   🎉  すべての手順が完了しました！              ${GREEN}${BOLD}║${RESET}"
echo -e "  ${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}ssh rpi@$TARGET_HOST${RESET}"
echo ""
