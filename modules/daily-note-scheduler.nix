{ config, pkgs, lib, ... }:

let
  cfg = config.services.daily-note-scheduler;

  skillDir = pkgs.runCommand "task-schedule-skill" {} ''
    mkdir -p $out
    cp ${../skills/task-schedule/SKILL.md}        $out/SKILL.md
    cp ${../skills/task-schedule/schedule_calc.sh} $out/schedule_calc.sh
    cp ${../skills/task-schedule/resolve_asset.sh} $out/resolve_asset.sh
    cp ${../skills/task-schedule/parse_asset.sh}   $out/parse_asset.sh
    cp ${../skills/task-schedule/write_asset.sh}   $out/write_asset.sh
    chmod +x $out/*.sh
  '';

  cacheDir = "/mnt/2disk/daily-note-scheduler";
in
{
  options.services.daily-note-scheduler = {
    enable = lib.mkEnableOption "Obsidian daily note auto-scheduler";

    user = lib.mkOption {
      type = lib.types.str;
      default = "rpi";
    };

    claudeBin = lib.mkOption {
      type = lib.types.str;
      default = "/home/rpi/.local/bin/claude";
      description = "claude CLI のパス";
    };
  };

  config = lib.mkIf cfg.enable {
    # HDD 作業ディレクトリ・スキルシムリンク
    systemd.tmpfiles.rules = [
      "d ${cacheDir}                      0755 ${cfg.user} ${cfg.user} -"
      "d ${cacheDir}/schedule_assets      0755 ${cfg.user} ${cfg.user} -"
      "d /home/${cfg.user}/.claude/skills 0755 ${cfg.user} ${cfg.user} -"
      "L /home/${cfg.user}/.claude/skills/task-schedule - - - - ${skillDir}"
    ];

    # web interface から直接呼び出すスクリプト
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "daily-note-scheduler" ''
        set -euo pipefail
        export VAULT_CACHE_DIR="${cacheDir}"
        export HOME="/home/${cfg.user}"
        export PATH="/home/${cfg.user}/.local/bin:/run/current-system/sw/bin:$PATH"

        STDERR_TMP=$(mktemp ${cacheDir}/stderr.XXXXXX)
        trap "rm -f $STDERR_TMP" EXIT

        if ! ${cfg.claudeBin} --print \
            "今日のデイリーノートをスケジューリングして。開始時刻が不明な場合は 08:00 とすること。" \
            2>"$STDERR_TMP"; then

          if grep -qi "401\|Invalid authentication\|credentials" "$STDERR_TMP"; then
            echo "================================================" >&2
            echo "Claude 認証切れ: 再認証が必要です。" >&2
            echo "Pi 上で以下を実行してください:" >&2
            echo "  sudo -u ${cfg.user} HOME=/home/${cfg.user} ${cfg.claudeBin}" >&2
            echo "================================================" >&2
            exit 2
          fi

          cat "$STDERR_TMP" >&2
          exit 1
        fi
      '')
    ];
  };
}
