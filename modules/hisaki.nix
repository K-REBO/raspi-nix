{ config, pkgs, lib, ... }:

let
  cfg = config.services.hisaki;

  hisakiBin = pkgs.rustPlatform.buildRustPackage {
    name = "hisaki";
    src = ../apps/hisaki;
    cargoLock.lockFile = ../apps/hisaki/Cargo.lock;
  };
in
{
  options.services.hisaki = {
    enable = lib.mkEnableOption "Hisaki event relay (discord_cli 経由)";

    port = lib.mkOption {
      type    = lib.types.port;
      default = 3001;
    };

    discordChannelId = lib.mkOption {
      type        = lib.types.str;
      description = "通知先の Discord チャンネル ID";
    };

    discordCliBin = lib.mkOption {
      type    = lib.types.str;
      default = "/home/rpi/.local/bin/discord_cli";
      description = "discord_cli バイナリのパス";
    };

    user = lib.mkOption {
      type    = lib.types.str;
      default = "rpi";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.hisaki-env = {
      file  = ../secrets/hisaki-env.age;
      mode  = "0440";
      owner = "root";
      group = cfg.user;
    };

    age.secrets.discord = {
      file  = ../secrets/discord.age;
      mode  = "0440";
      owner = "root";
      group = cfg.user;
    };

    systemd.services.hisaki = {
      description = "Hisaki Event Relay";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];
      serviceConfig = {
        Type            = "simple";
        User            = cfg.user;
        ExecStart       = "${hisakiBin}/bin/hisaki";
        Restart         = "on-failure";
        RestartSec      = "10s";
        EnvironmentFile = [
          config.age.secrets.hisaki-env.path   # HS_API_TOKEN
          config.age.secrets.discord.path       # DISCORD_TOKEN
        ];
        Environment = [
          "PORT=${toString cfg.port}"
          "DISCORD_CLI=${cfg.discordCliBin}"
          "DISCORD_CHANNEL_ID=${cfg.discordChannelId}"
          "RUST_LOG=info"
        ];
        StandardOutput = "journal";
        StandardError  = "journal";
      };
    };
  };
}
