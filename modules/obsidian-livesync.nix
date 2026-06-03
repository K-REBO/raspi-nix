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
  };

  config = lib.mkIf cfg.enable {
    age.secrets.couchdb-env = {
      file = ../secrets/couchdb-env.age;
      mode = "0400";
      owner = "root";
      group = "root";
    };

    # NixOS native CouchDB
    # configFile = /run/couchdb-init/admin.ini は couchdb-admin-config.service が書き込む
    # NixOS couchdb モジュールが ERL_FLAGS の末尾にこのパスを追加する
    services.couchdb = {
      enable = true;
      dataDir = cfg.dataDir;
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
        RuntimeDirectory = "couchdb-init";
        RuntimeDirectoryMode = "0750";
        ExecStart = pkgs.writeShellScript "couchdb-admin-config" ''
          set -a; source ${config.age.secrets.couchdb-env.path}; set +a
          printf '[admins]\n%s = %s\n' "$COUCHDB_USER" "$COUCHDB_PASSWORD" \
            > /run/couchdb-init/admin.ini
        '';
      };
    };

    systemd.services.couchdb = {
      requires = [ "couchdb-admin-config.service" "couchdb-data-chown.service" ];
      after    = [ "couchdb-admin-config.service" "couchdb-data-chown.service" ];
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

    # obsidian-vault daily sync (12:00)
    systemd.services.obsidian-vault-sync = {
      description = "Obsidian vault daily sync";
      after = [ "couchdb.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "obsidian-vault-sync" ''
          set -a; source ${config.age.secrets.couchdb-env.path}; set +a
          export COUCHDB_URL="http://127.0.0.1:${toString cfg.port}"
          exec ${obsidianVaultPkg}/bin/obsidian-vault sync
        '';
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
