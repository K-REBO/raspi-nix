#!/usr/bin/env bash
# migrate.sh — 既存 schedule_assets を YAML frontmatter 形式に変換（一回限り）
# Usage: migrate.sh

ASSETS_DIR="$HOME/.obsidian/schedule_assets"

convert() {
  local file="$1"
  # すでに frontmatter があればスキップ
  if head -1 "$file" | grep -q '^---$'; then
    echo "SKIP (already converted): $file"
    return
  fi
  echo "Converting: $file"
  local tmp=$(mktemp)
  cp "$file" "$tmp"
  # バックアップ
  cp "$file" "${file}.bak"
  # LLM に変換を依頼するのではなく、ここでは手動定義ファイルを直接置き換える
  echo "MANUAL: $file needs YAML frontmatter — see plan for format"
}

for f in "$ASSETS_DIR"/*.md; do
  convert "$f"
done
