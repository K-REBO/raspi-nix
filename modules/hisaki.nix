{ config, pkgs, lib, ... }:

let
  cfg = config.services.hisaki;

  hisakiBin = pkgs.rustPlatform.buildRustPackage {
    name = "hisaki";
    src = ../apps/hisaki;
    # 初回ビルド後に `nix build` を実行し、出力されたハッシュに差し替えること
    cargoHash = lib.fakeHash;
    nativeBuildInputs = [ pkgs.pkg-config ];
  };
in
{
  options.services.hisaki = {
    enable = lib.mkEnableOption "Hisaki event relay (Discord webhook forwarder)";

    port = lib.mkOption {
      type    = lib.types.port;
      default = 3001;
      description = "バインドポート (localhost のみ)";
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

    systemd.services.hisaki = {
      description = "Hisaki Event Relay";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network-online.target" ];
      wants       = [ "network-online.target" ];
      serviceConfig = {
        Type           = "simple";
        User           = cfg.user;
        ExecStart      = "${hisakiBin}/bin/hisaki";
        Restart        = "on-failure";
        RestartSec     = "10s";
        EnvironmentFile = config.age.secrets.hisaki-env.path;
        Environment    = [
          "PORT=${toString cfg.port}"
          "RUST_LOG=info"
        ];
        StandardOutput = "journal";
        StandardError  = "journal";
      };
    };
  };
}
