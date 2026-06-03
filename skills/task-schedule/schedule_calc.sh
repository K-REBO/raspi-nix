#!/usr/bin/env bash
# schedule_calc.sh — タイムライン計算エンジン
# Usage: schedule_calc.sh <input.md>
# stdout: ## schedule セクション（Markdown）
# stderr: MISSING リスト（LLM へのフォールバック情報）

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_CACHE_DIR="${VAULT_CACHE_DIR:-/mnt/2disk/daily-note-scheduler}"
ASSETS_DIR="$VAULT_CACHE_DIR/schedule_assets"
DEFAULTS="$ASSETS_DIR/_defaults.md"
mkdir -p "$ASSETS_DIR"
# vault から _defaults.md を取得 (なければ空ファイルで続行)
obsidian-vault read "schedule_assets/_defaults.md" > "$DEFAULTS" 2>/dev/null || touch "$DEFAULTS"

input="$1"
start_arg="${2:-}"  # 省略可能な start:HH:MM 引数

# ── ユーティリティ ──────────────────────────────────────────

# 分数を HH:MM に変換
to_hhmm() {
  local total_min=$1
  printf "%02d:%02d" $((total_min / 60)) $((total_min % 60))
}

# HH:MM を分数に変換
to_min() {
  local t=$1
  local h=${t%%:*}
  local m=${t##*:}
  echo $((10#$h * 60 + 10#$m))
}

# "(Xh)" / "(Xm)" / "(X分)" → 分数。マッチしなければ空文字
parse_inline_duration() {
  local s="$1"
  if [[ "$s" =~ \(([0-9]+)h\) ]]; then echo $(( ${BASH_REMATCH[1]} * 60 )); return; fi
  if [[ "$s" =~ \(([0-9]+)m\) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ "$s" =~ \(([0-9]+)分\) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  echo ""
}

# _defaults.md から指定セクション・キーの値（分数）を取得
lookup_defaults() {
  local section="$1"  # habit / tasks / travel
  local key="$2"
  "$SKILL_DIR/parse_asset.sh" "$DEFAULTS" --yaml | \
    awk -v sec="$section" -v k="$key" '
      $0 == sec":" { in_sec=1; next }
      in_sec && /^[^ ]/ { in_sec=0 }
      in_sec && $0 ~ "^  "k":" { gsub(/^  [^:]+: /,""); print; exit }
    '
}

# p: 記法から移動時間を解決（自宅→場所名 → 場所名 → 自宅→最寄り駅 の順で lookup）
lookup_travel() {
  local place="$1"
  local t
  t=$(lookup_defaults "travel" "自宅→${place}")
  [[ -n "$t" ]] && echo "$t" && return
  t=$(lookup_defaults "travel" "${place}")
  [[ -n "$t" ]] && echo "$t" && return
  lookup_defaults "travel" "自宅→最寄り駅"
}

# ── PARSE ──────────────────────────────────────────────────

# 開始時刻（ファイル内 `開始:` またはCLI引数 start:HH:MM）
start_raw=$(grep -m1 '^開始:' "$input" | sed 's/開始: *//')
[[ -z "$start_raw" && "$start_arg" =~ ^start:(.+)$ ]] && start_raw="${BASH_REMATCH[1]}"
start_min=""
[[ -n "$start_raw" ]] && start_min=$(to_min "$start_raw")

# セクション抽出（配列）— 状態機械方式（区間パターンは開始行自身にもマッチするため使用不可）
mapfile -t habit_lines    < <(awk '/^## habit$/{f=1;next} f&&/^## /{f=0} f&&/^- /{sub(/^- /,""); sub(/^\[ \] /,""); print}' "$input")
mapfile -t scheduled_lines < <(awk '/^## scheduled$/{f=1;next} f&&/^## /{f=0} f&&/^- /{sub(/^- /,""); sub(/^\[ \] /,""); if (/^`[0-9:]*-[0-9:]*` /) {sub(/^`/,""); sub(/` /," ")}; print}' "$input")
mapfile -t task_lines     < <(awk '/^## tasks$/{f=1;next} f&&/^## /{f=0} f&&/^- /{sub(/^- /,""); sub(/^\[ \] /,""); print}' "$input")

# fixed_sched: HH:MM-HH:MM あり（固定）、flex_sched: 時刻なし（自動配置）
declare -a fixed_sched_lines=()
declare -a flex_sched_lines=()
for sline in "${scheduled_lines[@]}"; do
  if [[ "$sline" =~ ^[0-9]{1,2}:[0-9][0-9]-[0-9]{1,2}:[0-9][0-9] ]]; then
    fixed_sched_lines+=("$sline")
  else
    flex_sched_lines+=("$sline")
  fi
done

# インラインサブタスク: parent_task → "sub1_text\x1Fsub2_text\x1F..."
declare -A sched_inline_subs=()
_isp_parent=""
while IFS= read -r _isp_line; do
  if [[ "$_isp_line" =~ ^-[[:space:]] ]]; then
    _isp_task="${_isp_line:2}"
    _isp_task="${_isp_task#\[ \] }"; _isp_task="${_isp_task#\[x\] }"
    _isp_parent="$(echo "$_isp_task" | sed 's/ *([^)]*)$//')"
  elif [[ "$_isp_line" =~ ^[[:space:]]+-[[:space:]] ]] && [[ -n "$_isp_parent" ]]; then
    _isp_sub="${_isp_line#"${_isp_line%%[! ]*}"}"
    _isp_sub="${_isp_sub#- }"; _isp_sub="${_isp_sub#\[ \] }"; _isp_sub="${_isp_sub#\[x\] }"
    if [[ -n "${sched_inline_subs[$_isp_parent]:-}" ]]; then
      sched_inline_subs["$_isp_parent"]+=$'\x1F'"$_isp_sub"
    else
      sched_inline_subs["$_isp_parent"]="$_isp_sub"
    fi
  fi
done < <(awk '/^## scheduled$/{f=1;next} f&&/^## /{f=0} f&&/^[[:space:]]*-/{print}' "$input")

# ── RESOLVE ────────────────────────────────────────────────
# 各タスクの duration を解決し、JSON 風の連想配列に保存
# MISSING があれば stderr に出力

declare -A durations=()    # タスク名 → 分数
declare -A has_subtasks=() # タスク名 → asset ファイルパス（サブタスクあり）
declare -a missing_items=()

resolve_duration() {
  local name="$1"
  local section="$2"  # habit or tasks
  local inline="$3"   # 入力のインライン時間指定

  # 1. asset ファイル
  local asset
  asset=$("$SKILL_DIR/resolve_asset.sh" "$name")
  if [[ -n "$asset" ]]; then
    local total
    total=$("$SKILL_DIR/parse_asset.sh" "$asset" --yaml | grep '^total:' | awk '{print $2}')
    if [[ -n "$total" ]]; then
      durations["$name"]="$total"
      has_subtasks["$name"]="$asset"
      return
    fi
  fi

  # 2. _defaults.md
  local def
  def=$(lookup_defaults "$section" "$name")
  if [[ -n "$def" ]]; then
    durations["$name"]="$def"
    return
  fi

  # 3. インライン指定
  if [[ -n "$inline" ]]; then
    durations["$name"]="$inline"
    return
  fi

  # 4. MISSING
  missing_items+=("$name")
  echo "MISSING:duration:$name" >&2
}

for line in "${habit_lines[@]}"; do
  name=$(echo "$line" | sed 's/ *([^)]*)$//')
  inline=$(parse_inline_duration "$line")
  resolve_duration "$name" "habit" "$inline"
done

for line in "${task_lines[@]}"; do
  name=$(echo "$line" | sed 's/ *([^)]*)$//')
  inline=$(parse_inline_duration "$line")
  resolve_duration "$name" "tasks" "$inline"
done

for line in "${flex_sched_lines[@]}"; do
  name=$(echo "$line" | sed 's/ *([^)]*)$//')
  inline=$(parse_inline_duration "$line")
  resolve_duration "$name" "tasks" "$inline"
done

# 開始時刻 MISSING
[[ -z "$start_min" ]] && echo "MISSING:start_time" >&2

# MISSING がある場合はここで終了（LLM が stderr を読んで ASK_ONCE する）
if [[ ${#missing_items[@]} -gt 0 ]] || [[ -z "$start_min" ]]; then
  exit 2
fi

# ── BUILD ──────────────────────────────────────────────────

cursor=$start_min
declare -a schedule_items=()
declare -a unscheduled=()
declare -a remaining_tasks=("${task_lines[@]}")

# 終端（最後の fixed scheduled の終了時刻か 24:00）
end_boundary=$((24 * 60))
for sline in "${scheduled_lines[@]}"; do
  if [[ "$sline" =~ ^[0-9]{1,2}:[0-9][0-9]-([0-9]{1,2}:[0-9][0-9]) ]]; then
    end_boundary=$(to_min "${BASH_REMATCH[1]}")
  fi
done

# タスクを配置（サブタスクがあれば展開、なければ単一ブロック）
place_any_task() {
  local name="$1"
  if [[ -n "${sched_inline_subs[$name]:-}" ]]; then
    place_inline_subtasks "$name"
  elif [[ -n "${has_subtasks[$name]:-}" ]]; then
    place_subtasks "${has_subtasks[$name]}" "$name"
  else
    place_task "$name"
  fi
}

# habit の配置
place_task() {
  local name="$1"
  local dur="${durations[$name]:-0}"
  local start=$cursor
  local end=$((cursor + dur))
  schedule_items+=("$(to_hhmm $start) $(to_hhmm $end) $name")
  cursor=$end
}

place_subtasks() {
  local asset="$1"
  local parent_name="$2"

  # subtasks を YAML から読み込む
  local yaml
  yaml=$("$SKILL_DIR/parse_asset.sh" "$asset" --yaml)

  # subtask ブロックをパース（簡易）
  local in_subtasks=0 cur_name="" cur_dur=0 cur_concurrent="false" cur_depends=""
  declare -a sub_names=() sub_durs=() sub_concurrent=() sub_depends=()

  while IFS= read -r yl; do
    if [[ "$yl" =~ ^subtasks: ]]; then in_subtasks=1; continue; fi
    if [[ $in_subtasks -eq 1 ]]; then
      if [[ "$yl" =~ ^[[:space:]]*-[[:space:]]name:[[:space:]](.*) ]]; then
        # 前のサブタスクを保存してから新しいサブタスクを開始
        [[ -n "$cur_name" ]] && { sub_names+=("$cur_name"); sub_durs+=("$cur_dur"); sub_concurrent+=("$cur_concurrent"); sub_depends+=("$cur_depends"); }
        cur_name="${BASH_REMATCH[1]}"
        cur_dur=0; cur_concurrent="false"; cur_depends=""
      elif [[ "$yl" =~ ^[[:space:]]*duration:[[:space:]]([0-9]+) ]]; then
        cur_dur="${BASH_REMATCH[1]}"
      elif [[ "$yl" =~ ^[[:space:]]*concurrent:[[:space:]](.+) ]]; then
        cur_concurrent="${BASH_REMATCH[1]}"
      elif [[ "$yl" =~ ^[[:space:]]*depends_on:[[:space:]](.+) ]]; then
        cur_depends="${BASH_REMATCH[1]}"
      elif [[ "$yl" =~ ^[^[:space:]] ]]; then
        # トップレベルキー → subtasks セクション終了
        [[ -n "$cur_name" ]] && { sub_names+=("$cur_name"); sub_durs+=("$cur_dur"); sub_concurrent+=("$cur_concurrent"); sub_depends+=("$cur_depends"); cur_name=""; }
        in_subtasks=0
      fi
    fi
  done <<< "$yaml"
  # ループ末尾で残っているサブタスクを保存
  [[ -n "$cur_name" ]] && { sub_names+=("$cur_name"); sub_durs+=("$cur_dur"); sub_concurrent+=("$cur_concurrent"); sub_depends+=("$cur_depends"); }

  # サブタスクをタイムラインに配置
  local i=0
  while [[ $i -lt ${#sub_names[@]} ]]; do
    local sname="${sub_names[$i]}"
    local sdur="${sub_durs[$i]}"
    local sconcurrent="${sub_concurrent[$i]}"
    local start=$cursor
    local end=$((cursor + sdur))
    schedule_items+=("$(to_hhmm $start) $(to_hhmm $end) $sname")

    # concurrent=true の場合、待機スロット（start〜end）に remaining_tasks を充填
    if [[ "$sconcurrent" == "true" ]] && [[ ${#remaining_tasks[@]} -gt 0 ]]; then
      cursor=$start  # 待機スロット開始点から充填
      local slot_end=$end
      local j=0
      while [[ $j -lt ${#remaining_tasks[@]} ]]; do
        local tname=$(echo "${remaining_tasks[$j]}" | sed 's/ *([^)]*)$//')
        local tdur="${durations[$tname]:-0}"
        if [[ $((cursor + tdur)) -le $slot_end ]]; then
          local ts=$cursor; local te=$((cursor + tdur))
          schedule_items+=("$(to_hhmm $ts) $(to_hhmm $te) $tname　←${sname}待ち")
          cursor=$te
          remaining_tasks=("${remaining_tasks[@]:0:$j}" "${remaining_tasks[@]:$((j+1))}")
        else
          j=$((j+1))
        fi
      done
      cursor=$slot_end  # 待機スロット終了後に cursor を合わせる
    else
      cursor=$end
    fi
    i=$((i+1))
  done
}

# インラインサブタスク展開（durationなしは親の残り時間を均等分割）
place_inline_subtasks() {
  local parent_name="$1"
  local subs_str="${sched_inline_subs[$parent_name]}"

  IFS=$'\x1F' read -ra sub_list <<< "$subs_str"

  # 既知durationの合計 & durationなしの数を集計
  local known_dur=0 no_dur_count=0
  for sub in "${sub_list[@]}"; do
    local d; d=$(parse_inline_duration "$sub")
    if [[ -n "$d" ]]; then known_dur=$((known_dur + d))
    else no_dur_count=$((no_dur_count + 1)); fi
  done

  # durationなしサブタスク1つあたりの時間（親の残り時間を均等分割）
  local parent_dur="${durations[$parent_name]:-0}"
  local remaining=$((parent_dur - known_dur))
  local each_no_dur=0
  [[ $no_dur_count -gt 0 && $remaining -gt 0 ]] && each_no_dur=$((remaining / no_dur_count))

  local total_dur=$((known_dur + each_no_dur * no_dur_count))
  local parent_start=$cursor
  schedule_items+=("$(to_hhmm $parent_start) $(to_hhmm $((parent_start + total_dur))) $parent_name")

  for sub in "${sub_list[@]}"; do
    local sname sdur start end
    sname=$(echo "$sub" | sed 's/ *([^)]*)$//')
    sdur=$(parse_inline_duration "$sub")
    [[ -z "$sdur" ]] && sdur=$each_no_dur
    start=$cursor
    end=$((cursor + sdur))
    schedule_items+=($'\t'"$(to_hhmm $start) $(to_hhmm $end) $sname")
    cursor=$end
  done
}

for line in "${habit_lines[@]}"; do
  name=$(echo "$line" | sed 's/ *([^)]*)$//')
  place_any_task "$name"
done

# scheduled を元の順序で配置（固定・flex を混在させたまま処理）
for sline in "${scheduled_lines[@]}"; do
  if [[ "$sline" =~ ^[0-9]{1,2}:[0-9][0-9]-[0-9]{1,2}:[0-9][0-9] ]]; then
    # 固定時刻あり
    time_range=$(echo "$sline" | grep -oE '^[0-9]{1,2}:[0-9][0-9]-[0-9]{1,2}:[0-9][0-9]')
    stime_str=${time_range%%-*}
    etime_str=${time_range##*-}
    sname=$(echo "$sline" | sed 's/^[0-9]\{1,2\}:[0-9][0-9]-[0-9]\{1,2\}:[0-9][0-9] //')
    stime=$(to_min "$stime_str")
    etime=$(to_min "$etime_str")

    # p: 記法で場所指定があれば移動時間を解決
    travel=0
    place=$(echo "$sname" | grep -o '(p:[^)]*)' | sed 's/(p://;s/)//')
    if [[ -n "$place" ]]; then
      travel_raw=$(lookup_travel "$place")
      [[ -n "$travel_raw" ]] && travel="$travel_raw"
      sname=$(echo "$sname" | sed 's/ *(p:[^)]*)//') # 表示名から p: を除去
    fi

    gap_end=$((stime - travel))

    # cursor → gap_end のギャップに remaining_tasks を充填
    i=0
    while [[ $i -lt ${#remaining_tasks[@]} ]]; do
      tname=$(echo "${remaining_tasks[$i]}" | sed 's/ *([^)]*)$//')
      tdur="${durations[$tname]:-0}"
      if [[ $((cursor + tdur)) -le $gap_end ]]; then
        place_any_task "$tname"
        remaining_tasks=("${remaining_tasks[@]:0:$i}" "${remaining_tasks[@]:$((i+1))}")
      else
        i=$((i+1))
      fi
    done

    # 移動を挿入
    if [[ $travel -gt 0 ]]; then
      schedule_items+=("$(to_hhmm $gap_end) $stime_str 移動（$sname）")
    fi

    # scheduled 本体（開始・終了とも確定）
    schedule_items+=("$stime_str $etime_str $sname")
    cursor=$etime  # 終了時刻から次のギャップ充填を開始
  else
    # 時刻なし（flex）: カーソル位置に即時配置
    name=$(echo "$sline" | sed 's/ *([^)]*)$//')
    place_any_task "$name"
  fi
done

# 残 tasks をスケジュール末尾に充填
# ※ for スナップショットではなく while インデックスループを使う。
# place_subtasks の concurrent 充填が remaining_tasks を動的に変更するため、
# 配置済みのタスクをループ内で即座に除去しないと重複配置が発生する。
i=0
while [[ $i -lt ${#remaining_tasks[@]} ]]; do
  name=$(echo "${remaining_tasks[$i]}" | sed 's/ *([^)]*)$//')
  dur="${durations[$name]:-0}"
  if [[ $((cursor + dur)) -le $end_boundary ]]; then
    place_any_task "$name"
    remaining_tasks=("${remaining_tasks[@]:0:$i}" "${remaining_tasks[@]:$((i+1))}")
  else
    unscheduled+=("$name")
    i=$((i+1))
  fi
done

# ── OUTPUT ─────────────────────────────────────────────────

echo "## schedule"
echo ""
_tab=$'\t'
for item in "${schedule_items[@]}"; do
  if [[ "$item" =~ ^${_tab}([0-9:]+)[[:space:]]([0-9:]+)[[:space:]](.+)$ ]]; then
    echo $'\t'"- [ ] \`${BASH_REMATCH[1]}-${BASH_REMATCH[2]}\` ${BASH_REMATCH[3]}"
  elif [[ "$item" =~ ^([0-9:]+)[[:space:]]-[[:space:]](.+)$ ]]; then
    echo "- [ ] \`${BASH_REMATCH[1]}-\` ${BASH_REMATCH[2]}"
  elif [[ "$item" =~ ^([0-9:]+)[[:space:]]([0-9:]+)[[:space:]](.+)$ ]]; then
    echo "- [ ] \`${BASH_REMATCH[1]}-${BASH_REMATCH[2]}\` ${BASH_REMATCH[3]}"
  fi
done

echo ""
echo "## unscheduled"
echo ""
if [[ ${#unscheduled[@]} -eq 0 ]]; then
  echo "（なし）"
else
  for u in "${unscheduled[@]}"; do
    echo "- $u"
  done
fi
