{ config, pkgs, lib, ... }:

let
  cfg = config.services.obsidian-tunnel;
in
{
  options.services.obsidian-tunnel = {
    enable = lib.mkEnableOption "Cloudflare Tunnel for Obsidian LiveSync";

    tunnelId = lib.mkOption {
      type = lib.types.str;
      default = "TUNNEL_ID_PLACEHOLDER";
      description = "Cloudflare Tunnel ID (set by setup.sh)";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "obsidian.bido.dev";
      description = "Domain name for the tunnel";
    };
  };

  config = lib.mkIf cfg.enable {
    # agenix シークレットの定義
    age.secrets.cloudflared-creds = {
      file = ../secrets/cloudflared-creds.age;
      mode = "0400";
      owner = "cloudflared";
      group = "cloudflared";
    };

    # cloudflared ユーザーとグループ
    users.users.cloudflared = {
      isSystemUser = true;
      group = "cloudflared";
    };
    users.groups.cloudflared = {};

    # Cloudflare Tunnel サービス
    services.cloudflared = {
      enable = true;
      tunnels = {
        "${cfg.tunnelId}" = {
          credentialsFile = config.age.secrets.cloudflared-creds.path;
          default = "http_status:404";
          ingress = {
            "${cfg.domain}" = {
              service = "http://localhost:5984";
            };
          };
        };
      };
    };

    # systemd サービスの依存関係設定
    systemd.services."cloudflared-tunnel-${cfg.tunnelId}" = {
      requires = [ "docker-obsidian-livesync.service" ];
      after = [ "docker-obsidian-livesync.service" "network-online.target" ];

      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";
      };
    };
  };
}
