{ config, pkgs, lib, ... }:

let
  cfg = config.services.obsidian-livesync;
in
{
  options.services.obsidian-livesync = {
    enable = lib.mkEnableOption "Obsidian Self-hosted LiveSync CouchDB server";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/data/couchdb";
      description = "Directory to store CouchDB data";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5984;
      description = "Port to bind CouchDB (localhost only)";
    };
  };

  config = lib.mkIf cfg.enable {
    # agenix シークレットの定義
    age.secrets.couchdb-env = {
      file = ../secrets/couchdb-env.age;
      mode = "0400";
      owner = "root";
      group = "root";
    };

    # データディレクトリの作成
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
    ];

    # Docker コンテナの設定
    virtualisation.oci-containers.containers.obsidian-livesync = {
      image = "docker.io/oleduc/docker-obsidian-livesync-couchdb:latest";
      autoStart = true;

      # localhost のみバインド
      ports = [
        "127.0.0.1:${toString cfg.port}:5984"
      ];

      # データボリューム
      volumes = [
        "${cfg.dataDir}:/opt/couchdb/data"
      ];

      # 環境変数ファイル
      environmentFiles = [
        config.age.secrets.couchdb-env.path
      ];

      # 依存関係: データディレクトリのマウント完了を待つ
      extraOptions = [
        "--pull=always"
      ];
    };

    # systemd サービスの依存関係設定
    systemd.services.docker-obsidian-livesync = {
      requires = [ "mnt-data.mount" ];
      after = [ "mnt-data.mount" "docker.service" ];

      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";
      };
    };
  };
}
