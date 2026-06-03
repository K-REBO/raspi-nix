{ config, pkgs, lib, pkgs-unstable, ... }:

let
  cfg = config.services.llama-server;
in {
  options.services.llama-server = {
    enable = lib.mkEnableOption "llama.cpp OpenAI-compatible inference server";

    port = lib.mkOption {
      type    = lib.types.port;
      default = 8080;
      description = "バインドポート";
    };

    modelDir = lib.mkOption {
      type    = lib.types.path;
      default = "/mnt/disk/llama-models";
      description = "モデルファイルの保存先 (HDD 推奨)";
    };

    modelFile = lib.mkOption {
      type    = lib.types.str;
      default = "qwen2.5-0.5b-instruct-q4_k_m.gguf";
    };

    modelUrl = lib.mkOption {
      type    = lib.types.str;
      default = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf";
    };

    contextSize = lib.mkOption {
      type    = lib.types.int;
      default = 2048;
    };

    nParallel = lib.mkOption {
      type    = lib.types.int;
      default = 1;
      description = "同時処理スロット数 (Pi 4B は 1 推奨)";
    };

    user = lib.mkOption {
      type    = lib.types.str;
      default = "llama";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group        = cfg.user;
    };
    users.groups.${cfg.user} = {};

    # モデルディレクトリを HDD 上に確保
    systemd.tmpfiles.rules = [
      "d ${cfg.modelDir} 0755 ${cfg.user} ${cfg.user} -"
    ];

    # ---- モデルダウンロード (HDD マウント後、初回のみ) ----
    systemd.services.llama-model-download = {
      description = "Download ${cfg.modelFile} to HDD";
      after    = [ "mnt-disk.mount" "network-online.target" ];
      requires = [ "mnt-disk.mount" ];
      wants    = [ "network-online.target" ];
      serviceConfig = {
        Type             = "oneshot";
        RemainAfterExit  = true;
        User             = cfg.user;
        ExecStart = let
          script = pkgs.writeShellScript "llama-download" ''
            DEST="${cfg.modelDir}/${cfg.modelFile}"
            if [ -f "$DEST" ]; then
              echo "model already present: $DEST"
              exit 0
            fi
            echo "downloading ${cfg.modelFile}..."
            ${pkgs.wget}/bin/wget \
              --progress=dot:giga \
              --tries=5 \
              --waitretry=30 \
              -O "$DEST.tmp" \
              "${cfg.modelUrl}"
            mv "$DEST.tmp" "$DEST"
            echo "download complete: $DEST"
          '';
        in "${script}";
        # 失敗時に中途ファイルを削除して再試行可能にする
        ExecStartPost = let
          cleanup = pkgs.writeShellScript "llama-download-cleanup" ''
            rm -f "${cfg.modelDir}/${cfg.modelFile}.tmp"
          '';
        in "+${cleanup}";
        # 書き込みは HDD のみ、SD カードへのアクセスを防ぐ
        ReadWritePaths = [ cfg.modelDir ];
      };
    };

    # ---- llama-server 本体 ----
    systemd.services.llama-server = {
      description = "llama.cpp server (${cfg.modelFile})";
      wantedBy = [ "multi-user.target" ];
      after    = [ "mnt-disk.mount" "network-online.target" "llama-model-download.service" ];
      requires = [ "mnt-disk.mount" "llama-model-download.service" ];
      serviceConfig = {
        Type       = "simple";
        User       = cfg.user;
        ExecStart  = ''
          ${pkgs-unstable.llama-cpp}/bin/llama-server \
            --model ${cfg.modelDir}/${cfg.modelFile} \
            --ctx-size ${toString cfg.contextSize} \
            --parallel ${toString cfg.nParallel} \
            --host 0.0.0.0 \
            --port ${toString cfg.port} \
            --log-disable
        '';
        Restart    = "on-failure";
        RestartSec = "15s";
        # ログは journald (volatile) — SD カード書き込みなし
        StandardOutput = "journal";
        StandardError  = "journal";
        # SD カード保護: 書き込みを HDD に限定
        ReadWritePaths = [ cfg.modelDir ];
      };
    };
  };
}
