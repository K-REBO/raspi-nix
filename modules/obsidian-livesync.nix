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

    dbName = lib.mkOption {
      type = lib.types.str;
      default = "obsidiannotes";
      description = "CouchDB 上の Obsidian LiveSync データベース名";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.couchdb-env = {
      file = ../secrets/couchdb-env.age;
      mode = "0440";
      owner = "couchdb";
      group = "couchdb";
    };

    # E2EE_PASSPHRASE と DB_NAME を格納するシークレット (obsidian-vault CLI 用)
    age.secrets.vault-env = {
      file = ../secrets/vault-env.age;
      mode = "0400";
      owner = "rpi";
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

        [os_mon]
        start_disk_sup = false

        [log]
        writer = stderr
        level  = notice

        [smoosh.ratio_dbs]
        min_priority = 2.0

        [smoosh.ratio_views]
        min_priority = 2.0
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

    # CouchDB 起動後に obsidian DB の _revs_limit を設定
    systemd.services.couchdb-setup = {
      description = "Configure CouchDB obsidian database settings";
      after  = [ "couchdb.service" ];
      wants  = [ "couchdb.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "couchdb";
        ExecStart = pkgs.writeShellScript "couchdb-setup" ''
          set -euo pipefail
          set -a; source ${config.age.secrets.couchdb-env.path}; set +a
          # CouchDB が起動するまで待機
          for i in $(seq 1 30); do
            if ${pkgs.curl}/bin/curl -sf "http://localhost:${toString cfg.port}/_up" >/dev/null 2>&1; then
              break
            fi
            sleep 2
          done
          # obsidian DB の revs_limit を 20 に設定（デフォルト 1000 は大きすぎる）
          ${pkgs.curl}/bin/curl -sf -X PUT \
            "http://''${COUCHDB_USER}:''${COUCHDB_PASSWORD}@localhost:${toString cfg.port}/${cfg.dbName}/_revs_limit" \
            -H "Content-Type: application/json" \
            -d "20"
        '';
      };
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
        ExecStartPre = "+${pkgs.writeShellScript "obsidian-vault-sync-pre" ''
          mkdir -p ${cfg.syncDir}
          chown rpi ${cfg.syncDir}
        ''}";
        ExecStart = pkgs.writeShellScript "obsidian-vault-sync" ''
          set -euo pipefail
          set -a
          source ${config.age.secrets.couchdb-env.path}
          source ${config.age.secrets.vault-env.path}
          set +a
          export COUCHDB_URL="http://127.0.0.1:${toString cfg.port}"
          export DB_NAME="${cfg.dbName}"
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
