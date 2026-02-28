#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# ── ビルド ────────────────────────────────────────────────
echo "▶ nix build .#sdImage"
nix build .#sdImage

IMG=$(ls result/sd-image/*.img.zst 2>/dev/null | head -1 || true)
IMG=${IMG:-$(ls result/sd-image/*.img 2>/dev/null | head -1 || true)}
[ -z "$IMG" ] && { echo "ERROR: イメージが見つかりません"; exit 1; }
echo "▶ $IMG  ($(du -h "$IMG" | cut -f1))"

# ── デバイス選択 ───────────────────────────────────────────
echo ""
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v loop
echo ""
read -rp "書き込み先デバイス (例: sdb, mmcblk0): " DEV_IN
DEV="/dev/${DEV_IN#/dev/}"
[ ! -b "$DEV" ] && { echo "ERROR: $DEV が見つかりません"; exit 1; }

SIZE=$(lsblk -d -o SIZE "$DEV" | tail -1 | tr -d ' ')
echo ""
echo "  $DEV ($SIZE) の全データが消去されます"
read -rp "確認のためデバイス名を再入力: " CONFIRM
[[ "$CONFIRM" == "$DEV_IN" || "$CONFIRM" == "$DEV" ]] || { echo "キャンセル"; exit 0; }

# ── アンマウント ───────────────────────────────────────────
for part in $(lsblk -lno NAME "$DEV" | tail -n +2); do
    mountpoint -q "/dev/$part" 2>/dev/null && { echo "▶ umount /dev/$part"; sudo umount "/dev/$part"; } || true
done

# ── 書き込み ───────────────────────────────────────────────
echo "▶ 書き込み中..."
if [[ "$IMG" == *.zst ]]; then
    zstd -d --stdout "$IMG" | sudo dd of="$DEV" bs=4M conv=fsync status=progress
else
    sudo dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
fi
sync
echo "▶ 書き込み完了"

# ── ext4 64bit 修正 (U-Boot互換) ──────────────────────────
if [[ "$DEV" == *mmcblk* || "$DEV" == *nvme* ]]; then
    ROOT="${DEV}p2"
else
    ROOT="${DEV}2"
fi
echo "▶ ext4 64bit フィーチャーを修正中..."
sudo e2fsck -fy "$ROOT" >/dev/null 2>&1 || true
sudo resize2fs -s "$ROOT" >/dev/null 2>&1 || true
sudo e2fsck -fy "$ROOT" >/dev/null 2>&1 || true

echo ""
echo "▶ 完了!"
