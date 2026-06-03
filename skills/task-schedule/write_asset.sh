#!/usr/bin/env bash
# write_asset.sh — asset ファイルの YAML frontmatter にキーを追記または更新
# Usage: write_asset.sh <file> <section> <key> <value>
#   section: habit / tasks / travel / (root)
#   例: write_asset.sh _defaults.md habit "英語の勉強" 45
#   例: write_asset.sh 洗濯.md root total 90

file="$1"
section="$2"
key="$3"
value="$4"

if [[ ! -f "$file" ]]; then
  echo "ERROR: file not found: $file" >&2
  exit 1
fi

tmp=$(mktemp)

if [[ "$section" == "root" ]]; then
  # frontmatter のルートレベルにキーを追加または更新
  awk -v key="$key" -v val="$value" '
    /^---$/ && !found { found=1; print; next }
    found && /^---$/ {
      if (!written) { print key": "val; written=1 }
      print; found=0; next
    }
    found && $0 ~ "^"key":" { print key": "val; written=1; next }
    { print }
  ' "$file" > "$tmp"
else
  # 指定セクション配下に "  key: value" を追加または更新
  awk -v sec="$section" -v key="$key" -v val="$value" '
    /^---$/ && !started { started=1; print; next }
    started && /^---$/ {
      if (!written) {
        # セクション末尾に追記（セクションが存在しない場合は追加）
      }
      print; started=0; next
    }
    started && $0 == sec":" { in_sec=1; print; next }
    in_sec && /^[^ ]/ && !/^  / { in_sec=0 }
    in_sec && $0 ~ "^  "key":" { print "  "key": "val; written=1; next }
    { print }
    in_sec && /^---$/ && !written { print "  "key": "val; written=1 }
  ' "$file" > "$tmp"
fi

mv "$tmp" "$file"
echo "Updated $file: [$section] $key = $value"

# HDD キャッシュファイルなら vault にも書き戻す
VAULT_CACHE_DIR="${VAULT_CACHE_DIR:-/mnt/2disk/daily-note-scheduler}"
if [[ "$file" == "$VAULT_CACHE_DIR/"* ]]; then
  vault_path="${file#"$VAULT_CACHE_DIR/"}"
  obsidian-vault write "$vault_path" < "$file" >/dev/null 2>&1 || true
fi
