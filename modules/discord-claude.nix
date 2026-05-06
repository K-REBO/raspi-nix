{ config, lib, ... }:

let
  cfg = config.services.discord-claude;
in {
  options.services.discord-claude = {
    enable    = lib.mkEnableOption "Claude Code Discord channel (official Anthropic plugin)";
    user      = lib.mkOption { type = lib.types.str; default = "rpi"; };
    claudeBin = lib.mkOption { type = lib.types.str; default = "/home/rpi/.local/bin/claude"; };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.discord-claude = {
      description = "Claude Code Discord Channel";
      after    = [ "network-online.target" ];
      wants    = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type       = "simple";
        ExecStart  = "${cfg.claudeBin} --channels plugin:discord@claude-plugins-official";
        Restart    = "on-failure";
        RestartSec = "15s";
        User       = cfg.user;
        Environment = [
          "HOME=/home/${cfg.user}"
          "PATH=/home/${cfg.user}/.local/bin:/run/current-system/sw/bin:/usr/bin:/bin"
        ];
        StandardOutput = "journal";
        StandardError  = "journal";
      };
    };
  };
}
