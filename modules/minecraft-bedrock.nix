{ config, pkgs, lib, ... }:

let
  cfg = config.services.minecraft-bedrock;
  playit = pkgs.stdenv.mkDerivation {
    name    = "playit";
    version = "latest";
    src     = pkgs.fetchurl {
      url    = "https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-linux-aarch64";
      sha256 = "0rhzc005vwp8b7k5h2rl82430dl8w19n63hj1bc722n4vb7a2gyd";
    };
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      cp $src $out/bin/playit
      chmod +x $out/bin/playit
    '';
  };
in
{
  options.services.minecraft-bedrock = {
    enable = lib.mkEnableOption "Minecraft Bedrock Dedicated Server";

    dataDir = lib.mkOption {
      type    = lib.types.path;
      default = "/mnt/disk/minecraft";
      description = "ワールドデータの永続化ディレクトリ（外付けストレージ推奨）";
    };

    serverName = lib.mkOption {
      type    = lib.types.str;
      default = "Bedrock Server";
    };

    maxPlayers = lib.mkOption {
      type    = lib.types.ints.positive;
      default = 10;
    };

    gamemode = lib.mkOption {
      type    = lib.types.enum [ "survival" "creative" "adventure" ];
      default = "survival";
    };

    difficulty = lib.mkOption {
      type    = lib.types.enum [ "peaceful" "easy" "normal" "hard" ];
      default = "normal";
    };

    playit.enable = lib.mkEnableOption "playit.gg tunnel agent";

    backup = {
      enable = lib.mkOption {
        type    = lib.types.bool;
        default = true;
        description = "rsync による自動バックアップを有効にする";
      };
      dir = lib.mkOption {
        type    = lib.types.path;
        default = "/mnt/disk/minecraft-backups";
        description = "バックアップ先ディレクトリ";
      };
      schedule = lib.mkOption {
        type    = lib.types.str;
        default = "*-*-* 04:00:00";
        description = "バックアップ実行タイミング（systemd OnCalendar 形式）";
      };
      keepDays = lib.mkOption {
        type    = lib.types.ints.positive;
        default = 7;
        description = "何日分のバックアップを保持するか";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # データディレクトリ作成
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0755 root root -"
      ];

      # Minecraft Bedrock コンテナ
      virtualisation.oci-containers.containers.minecraft-bedrock = {
        image     = "docker.io/itzg/minecraft-bedrock-server:latest";
        autoStart = true;
        ports     = [ "19132:19132/udp" ];
        volumes   = [ "${cfg.dataDir}:/data" ];
        environment = {
          EULA        = "TRUE";
          SERVER_NAME = cfg.serverName;
          MAX_PLAYERS = toString cfg.maxPlayers;
          GAMEMODE    = cfg.gamemode;
          DIFFICULTY  = cfg.difficulty;

          # パフォーマンス（Raspberry Pi 向けに抑えめ）
          VIEW_DISTANCE        = "10";  # デフォルト10。重い場合は8に下げる
          TICK_DISTANCE        = "4";   # デフォルト4（最小値）、負荷軽減
          MAX_THREADS          = "0";   # 0=コア数に応じて自動

          # プレイヤー管理
          PLAYER_IDLE_TIMEOUT  = "30";  # 30分放置でキック（0=無効）
          ONLINE_MODE          = "true"; # Microsoftアカウント認証を要求

          # チート
          ALLOW_CHEATS         = "false";
        };
        extraOptions = [ "--pull=always" ];
      };

      # 自動生成ユニットへの依存関係追加
      # wants（requires でない）→ マウント失敗でもシステム起動は継続
      systemd.services.docker-minecraft-bedrock = {
        wants = [ "mnt-disk.mount" ];
        after = [ "mnt-disk.mount" "docker.service" ];
        serviceConfig = {
          Restart    = "always";
          RestartSec = "10s";
        };
      };

      # ファイアウォール: UDP 19132 開放
      networking.firewall.allowedUDPPorts = [ 19132 ];
    }

    (lib.mkIf cfg.backup.enable {
      systemd.tmpfiles.rules = [
        "d ${cfg.backup.dir} 0755 root root -"
      ];

      systemd.services.minecraft-bedrock-backup = {
        description = "Minecraft Bedrock World Backup";
        # サーバーが起動済みの場合のみ実行（停止中でも worlds/ はそのままコピー可）
        after  = [ "docker-minecraft-bedrock.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "mc-backup" ''
            set -euo pipefail
            TIMESTAMP=$(date +%Y%m%d-%H%M%S)
            DEST="${cfg.backup.dir}/$TIMESTAMP"
            SRC="${cfg.dataDir}/worlds"

            if [ ! -d "$SRC" ]; then
              echo "worlds ディレクトリが見つかりません: $SRC" >&2
              exit 1
            fi

            # rsync でスナップショット作成（ハードリンクで差分コピー）
            LATEST="${cfg.backup.dir}/latest"
            if [ -d "$LATEST" ]; then
              ${pkgs.rsync}/bin/rsync -a --link-dest="$LATEST" "$SRC/" "$DEST/"
            else
              ${pkgs.rsync}/bin/rsync -a "$SRC/" "$DEST/"
            fi

            # latest シンボリックリンクを更新
            ln -sfn "$DEST" "$LATEST"

            # 古いバックアップを削除（keepDays 日より古いもの）
            find "${cfg.backup.dir}" -maxdepth 1 -type d -name '20*' \
              -mtime +${toString cfg.backup.keepDays} -exec rm -rf {} +

            echo "バックアップ完了: $DEST"
          '';
        };
      };

      systemd.timers.minecraft-bedrock-backup = {
        wantedBy  = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.backup.schedule;
          Persistent = true;  # 停止中に期限を過ぎた場合、起動後すぐに実行
        };
      };
    })

    (lib.mkIf cfg.playit.enable {
      age.secrets.playit-secret = {
        file  = ../secrets/playit-secret.age;
        mode  = "0400";
        owner = "root";
        group = "root";
      };

      # 書き込み可能な作業ディレクトリ（playit がシークレットを更新するため必要）
      systemd.tmpfiles.rules = [
        "d /var/lib/playit 0700 root root -"
      ];

      systemd.services.playit = {
        description = "playit.gg tunnel agent";
        after       = [ "network-online.target" "docker-minecraft-bedrock.service" ];
        wants       = [ "network-online.target" ];
        requires    = [ "docker-minecraft-bedrock.service" ];
        wantedBy    = [ "multi-user.target" ];
        serviceConfig = {
          # 初回のみ agenix シークレットをコピー。クレーム後は playit が自分で更新するので上書きしない
          ExecStartPre = "${pkgs.bash}/bin/sh -c '[ -f /var/lib/playit/secret ] || cp ${config.age.secrets.playit-secret.path} /var/lib/playit/secret'";
          ExecStart    = "${playit}/bin/playit --secret_path /var/lib/playit/secret -s start";
          Restart      = "always";
          RestartSec   = "10s";
          User         = "root";
        };
      };
    })
  ]);
}
