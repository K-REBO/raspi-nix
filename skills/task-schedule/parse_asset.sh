#!/usr/bin/env bash
# parse_asset.sh — asset ファイルから YAML frontmatter または MD 本文を抽出
# Usage: parse_asset.sh <file> [--yaml | --md]
#   --yaml  YAML frontmatter のみ出力（デフォルト）
#   --md    MD 本文のみ出力（LLM 向け補足テキスト）

file="$1"
mode="${2:---yaml}"

if [[ ! -f "$file" ]]; then
  echo "ERROR: file not found: $file" >&2
  exit 1
fi

case "$mode" in
  --yaml)
    # --- と --- の間を抽出（区切り行自体は除く）
    awk '/^---$/{if(found){exit}else{found=1;next}} found{print}' "$file"
    ;;
  --md)
    # 2つ目の --- より後の行を出力
    awk 'count==2{print} /^---$/{count++}' "$file"
    ;;
  *)
    echo "Usage: parse_asset.sh <file> [--yaml | --md]" >&2
    exit 1
    ;;
esac
