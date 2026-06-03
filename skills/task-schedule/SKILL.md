---
name: task-schedule
version: 2.0.0
description: "入力markdownからその日の時間ブロックスケジュールを生成する。/task-schedule、'スケジュールを組んで'、'今日の予定を組んで'、'タスクを時間割にして' と言ったとき使用。"
metadata:
  openclaw:
    category: "recipe"
    domain: "productivity"
---

# Task Schedule

入力 markdown の `habit` / `scheduled` / `tasks` セクションを読み、時間ブロックスケジュールを生成する。
計算処理は `schedule_calc.sh` に委譲し、LLM は未知タスクの補完と出力書き込みのみ担当する。

---

## INPUT FORMAT

```
開始: HH:MM

## habit
- タスク名

## scheduled
- HH:MM-HH:MM 予定名              # 移動なし
- HH:MM-HH:MM 予定名(p:場所名)    # p: で場所指定 → 移動時間を自動挿入
- タスク名                         # インラインサブタスクを持てる
  - サブタスク名 (Xh|Xm|X分)      # 全サブタスクに duration があれば個別展開

## tasks
- タスク名 (Xh|Xm|X分)  ← 省略可
```

---

## FLOW

```
STEP 1 — CALC
  1. 今日の vault パスを計算:
       WEEKDAYS=("日曜日" "月曜日" "火曜日" "水曜日" "木曜日" "金曜日" "土曜日")
       DOW=$(date +%w)
       VAULT_PATH="daily/$(date +%Y)_$(date +%m)_$(date +%-d)(${WEEKDAYS[$DOW]}).md"

  2. vault からデイリーノートを取得して HDD に保存:
       echo "::step::fetch::デイリーノートを取得中 ($VAULT_PATH)" >&2
       INPUT="${VAULT_CACHE_DIR:-/mnt/2disk/daily-note-scheduler}/input.md"
       obsidian-vault read "$VAULT_PATH" > "$INPUT"
       echo "::step-done::fetch" >&2

  3. schedule_calc.sh を実行:
       echo "::step::calc::スケジュールを計算中" >&2
       bash ~/.claude/skills/task-schedule/schedule_calc.sh "$INPUT"
       # 計算完了は exit code で判断 (step-done は STEP 3 で emit)

  exit 0 → stdout に ## schedule が出力された → STEP 3 へ
  exit 2 → stderr に MISSING リストが出力された → STEP 2 へ

STEP 2 — ASK_ONCE
  stderr の MISSING を読み、以下のフォーマットで1回だけ質問する:

  「以下を教えてください：
  [MISSING:start_time がある場合] 1. 開始時刻:
  [MISSING:duration:X がある場合] 2. 所要時間:
     - X: 何分？」

  回答を得たら:
  - 新規 duration → write_asset.sh で HDD の _defaults.md に追記 (vault にも自動反映):
      bash ~/.claude/skills/task-schedule/write_asset.sh \
        "${VAULT_CACHE_DIR:-/mnt/2disk/daily-note-scheduler}/schedule_assets/_defaults.md" \
        tasks "<タスク名>" <分数>
  - 開始時刻 → INPUT ファイルの先頭に "開始: HH:MM" を追記
  再度 STEP 1 の手順 3 を実行する

STEP 3 — WRITE
  STEP 1 で計算した VAULT_PATH に書き戻す:

  echo "::step-done::calc" >&2
  echo "::step::write::Vault に書き戻し中 ($VAULT_PATH)" >&2
  obsidian-vault read "$VAULT_PATH" でファイル全体を取得し、
  ## today セクション直後に ## schedule を追記（既にある場合は ## schedule から
  ## unscheduled の末尾まで上書き）。
  obsidian-vault write "$VAULT_PATH" で vault に反映する。
  echo "::step-done::write" >&2
```

---

## OUTPUT RULES

- 各行: `- [ ] \`HH:MM-HH:MM\` タスク名`
- scheduled: `` `HH:MM-HH:MM` ``（開始・終了とも必須）
- 同時進行補足: `タスク名　←待機タスク名待ち`
- `## unscheduled` セクションは常に出力（空なら「なし」）

---

## LLM FALLBACK（未知タスク処理）

`resolve_asset.sh` がファイルを返さず `_defaults.md` にもないタスクは:
1. タスク名の表記ゆれを解決して再検索（「をする」語尾除去等）
2. それでも不明なら MISSING として ASK_ONCE に含める
3. 回答後、`write_asset.sh` または `_defaults.md` に保存する

新規 asset ファイルが必要なケース（サブタスク・depends_on がある）:
`${VAULT_CACHE_DIR:-/mnt/2disk/daily-note-scheduler}/schedule_assets/<タスク名>.md` を
YAML frontmatter 形式で作成し、write_asset.sh 経由で vault にも書き戻す。
