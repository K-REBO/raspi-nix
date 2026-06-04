{ config, pkgs, lib, obsidianVaultPkg, ... }:

let
  cfg = config.services.obsidian-livesync;
in
{
  options.services.obsidian-livesync = {
    enable = lib.mkEnableOption "Obsidian Self-hosted LiveSync CouchDB server";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/disk/couchdb";
      description = "Directory to store CouchDB data";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5984;
      description = "Port to bind CouchDB (localhost only)";
    };

    syncDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/2disk/obsidian-backup";
      description = "obsidian-vault sync の出力先ディレクトリ (HDD)";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.couchdb-env = {
      file = ../secrets/couchdb-env.age;
      mode = "0440";
      owner = "couchdb";
      group = "couchdb";
    };

    # NixOS native CouchDB
    # configFile = /run/couchdb-init/admin.ini は couchdb-admin-config.service が書き込む
    # NixOS couchdb モジュールが ERL_FLAGS の末尾にこのパスを追加する
    services.couchdb = {
      enable = true;
      databaseDir = cfg.dataDir;
      viewIndexDir = cfg.dataDir;
      bindAddress = "127.0.0.1";
      port = cfg.port;
      configFile = "/run/couchdb-init/admin.ini";
      extraConfig = ''
        [httpd]
        enable_cors = true

        [cors]
        origins     = *
        credentials = true
        headers     = accept, authorization, content-type, origin, referer
        methods     = GET, PUT, POST, HEAD, DELETE

        [cluster]
        n = 1
        q = 1

        [couch_httpd_auth]
        timeout = 600

        [log]
        writer = stderr
        level  = notice
      '';
    };

    # agenix シークレットから管理者資格情報を /run/couchdb-init/admin.ini に書き込む
    systemd.services.couchdb-admin-config = {
      description = "Generate CouchDB admin config from agenix secret";
      before = [ "couchdb.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "couchdb";
        RuntimeDirectory = "couchdb-init";
        RuntimeDirectoryMode = "0750";
        ExecStart = pkgs.writeShellScript "couchdb-admin-config" ''
          set -euo pipefail
          set -a; source ${config.age.secrets.couchdb-env.path}; set +a
          if [ -z "''${COUCHDB_USER:-}" ] || [ -z "''${COUCHDB_PASSWORD:-}" ]; then
            echo "couchdb-env: COUCHDB_USER または COUCHDB_PASSWORD が未設定" >&2
            exit 1
          fi
          printf '[admins]\n%s = %s\n' "$COUCHDB_USER" "$COUCHDB_PASSWORD" \
            > /run/couchdb-init/admin.ini
        '';
      };
    };

    systemd.services.couchdb = {
      requires  = [ "couchdb-admin-config.service" "couchdb-data-chown.service" ];
      after     = [ "couchdb-admin-config.service" "couchdb-data-chown.service" ];
      # admin-config が停止したら couchdb も停止させ admin-party 状態を防ぐ
      bindsTo   = [ "couchdb-admin-config.service" ];
    };

    # Docker→native 移行: データディレクトリのオーナーを couchdb ユーザーに修正
    systemd.services.couchdb-data-chown = {
      description = "Fix CouchDB data directory ownership (Docker→native migration)";
      before = [ "couchdb.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/chown -R couchdb:couchdb ${cfg.dataDir}";
      };
    };

    # obsidian-vault sync: CouchDB → ファイルシステムへ毎日12:00に書き出す
    systemd.services.obsidian-vault-sync = {
      description = "Obsidian vault daily sync to ${cfg.syncDir}";
      after    = [ "couchdb.service" "mnt-2disk.mount" ];
      wants    = [ "couchdb.service" ];
      requires = [ "mnt-2disk.mount" ];
      serviceConfig = {
        Type = "oneshot";
        User = "rpi";
        ExecStart = pkgs.writeShellScript "obsidian-vault-sync" ''
          set -euo pipefail
          set -a; source ${config.age.secrets.couchdb-env.path}; set +a
          export COUCHDB_URL="http://127.0.0.1:${toString cfg.port}"
          mkdir -p ${cfg.syncDir}
          exec ${obsidianVaultPkg}/bin/obsidian-vault sync ${cfg.syncDir} --delete
        '';
        StandardOutput = "journal";
        StandardError  = "journal";
      };
    };

    systemd.timers.obsidian-vault-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "12:00:00";
        Persistent = true;
      };
    };
  };
}
