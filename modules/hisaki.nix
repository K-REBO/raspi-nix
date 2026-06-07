{ config, pkgs, lib, discordBridgeSrc, ... }:

let
  cfg = config.services.hisaki;

  hisakiBin = pkgs.rustPlatform.buildRustPackage {
    name = "hisaki";
    src = ../apps/hisaki;
    cargoLock.lockFile = ../apps/hisaki/Cargo.lock;
  };

  discordCliBin = pkgs.rustPlatform.buildRustPackage {
    name = "discord_bridge";
    src = discordBridgeSrc;
    cargoLock.lockFile = "${discordBridgeSrc}/Cargo.lock";
    cargoBuildFlags = [ "--bin" "discord_cli" ];
  };
in
{
  options.services.hisaki = {
    enable = lib.mkEnableOption "Hisaki event relay (discord_cli 経由)";

    port = lib.mkOption {
      type    = lib.types.port;
      default = 3001;
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
          config.age.secrets.hisaki-env.path   # HS_API_TOKEN, DISCORD_CHANNEL_ID
          config.age.secrets.discord.path       # DISCORD_TOKEN
        ];
        Environment = [
          "PORT=${toString cfg.port}"
          "DISCORD_CLI=${discordCliBin}/bin/discord_cli"
          "RUST_LOG=info"
        ];
        StandardOutput = "journal";
        StandardError  = "journal";
      };
    };
  };
}
