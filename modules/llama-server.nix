{ config, pkgs, lib, ... }:

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
      default = 1024;
    };

    threads = lib.mkOption {
      type    = lib.types.int;
      default = 3;
      description = "CPUスレッド数 (Pi 4B は 3 推奨、1コアをシステム用に残す)";
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

    systemd.tmpfiles.rules = [
      "d ${cfg.modelDir} 0755 ${cfg.user} ${cfg.user} -"
    ];

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
        ExecStartPost = let
          cleanup = pkgs.writeShellScript "llama-download-cleanup" ''
            rm -f "${cfg.modelDir}/${cfg.modelFile}.tmp"
          '';
        in "+${cleanup}";
        ReadWritePaths = [ cfg.modelDir ];
      };
    };

    systemd.services.llama-server = {
      description = "llama.cpp server (${cfg.modelFile})";
      wantedBy = [ "multi-user.target" ];
      after    = [ "mnt-disk.mount" "network-online.target" "llama-model-download.service" ];
      requires = [ "mnt-disk.mount" "llama-model-download.service" ];
      serviceConfig = {
        Type       = "simple";
        User       = cfg.user;
        ExecStart  = ''
          ${pkgs.llama-cpp}/bin/llama-server \
            --model ${cfg.modelDir}/${cfg.modelFile} \
            --ctx-size ${toString cfg.contextSize} \
            --parallel ${toString cfg.nParallel} \
            --threads ${toString cfg.threads} \
            --host 0.0.0.0 \
            --port ${toString cfg.port} \
            --no-warmup \
            --cache-ram 0
        '';
        Restart    = "on-failure";
        RestartSec = "15s";
        CPUQuota   = "300%";
        MemoryHigh = "700M";
        MemoryMax  = "800M";
        ReadWritePaths = [ cfg.modelDir ];
        StandardOutput = "journal";
        StandardError  = "journal";
      };
    };
  };
}
