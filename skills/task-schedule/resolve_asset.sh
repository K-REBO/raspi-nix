#!/usr/bin/env bash
# resolve_asset.sh — タスク名から schedule_assets のファイルパスを解決 (vault 経由)
# Usage: resolve_asset.sh <task-name>
# 出力: マッチしたファイルの絶対パス（HDD キャッシュ）、なければ空文字

VAULT_CACHE_DIR="${VAULT_CACHE_DIR:-/mnt/2disk/daily-note-scheduler}"
ASSETS_DIR="$VAULT_CACHE_DIR/schedule_assets"
mkdir -p "$ASSETS_DIR"

name="$1"
stripped=$(echo "$name" | sed 's/をする$//;s/する$//;s/を行う$//;s/をやる$//;s/やる$//')

# 完全一致・語尾除去: obsidian-vault read で取得を試みる
for attempt in "$name" "$stripped"; do
  local_path="$ASSETS_DIR/${attempt}.md"
  if obsidian-vault read "schedule_assets/${attempt}.md" > "$local_path" 2>/dev/null; then
    echo "$local_path"
    exit 0
  fi
  rm -f "$local_path"
done

# 前方一致: obsidian-vault list で候補を絞る
match=$(obsidian-vault list "schedule_assets/" 2>/dev/null \
  | grep -E "schedule_assets/(${name}|${stripped})" \
  | head -1)

if [[ -n "$match" ]]; then
  local_path="$ASSETS_DIR/$(basename "$match")"
  obsidian-vault read "$match" > "$local_path" 2>/dev/null && echo "$local_path"
fi
