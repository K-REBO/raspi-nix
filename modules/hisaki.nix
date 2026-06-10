{ config, pkgs, lib, discordBridgeSrc, rustOverlay, ... }:

let
  cfg = config.services.hisaki;

  hisakiBin = pkgs.rustPlatform.buildRustPackage {
    name = "hisaki";
    src = ../apps/hisaki;
    cargoLock.lockFile = ../apps/hisaki/Cargo.lock;
  };

  # discord_bridge は edition2024 を使用するため Rust 1.85+ が必要。
  # nixpkgs 24.11 の Rust 1.82 では不可のため rust-overlay で上書きする。
  buildPkgsWithRust = pkgs.buildPackages.extend rustOverlay.overlays.default;
  rustToolchain = buildPkgsWithRust.rust-bin.stable.latest.default.override {
    targets = [ "aarch64-unknown-linux-gnu" ];
  };
  discordRustPlatform = pkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };

  discordCliBin = discordRustPlatform.buildRustPackage {
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
    };

    age.secrets.discord = {
      file  = ../secrets/discord.age;
      mode  = "0440";
      owner = "root";
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
