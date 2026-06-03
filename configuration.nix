{ config, pkgs, lib, ... }:

{
  imports = [
    ./modules/obsidian-livesync.nix
    ./modules/obsidian-livesync-backup.nix
    ./modules/llama-server.nix
    ./modules/web-interface.nix
    ./modules/daily-note-scheduler.nix
  ];

  networking.hostName = "nixpi";
  time.timeZone = "Asia/Tokyo";

  users.users.rpi = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHurSJOCksQe93WR+fEYP9MiyJXNcnrz58hG0mRZOMHM"
    ];
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  # sshdをOOMキラーから保護・ハング検出・自動再起動
  systemd.services.sshd.serviceConfig = {
    OOMScoreAdjust = -1000;
    Restart = "always";
    RestartSec = "5s";
    WatchdogSec = "30s";
  };
  systemd.services.sshd.unitConfig = {
    StartLimitIntervalSec = "120s";
    StartLimitBurst = 5;
  };

  security.sudo.wheelNeedsPassword = false;

  # Tailscale VPN
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    extraUpFlags = [ "--ssh" ];
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    allowedUDPPorts = [ config.services.tailscale.port ];
    trustedInterfaces = [ "tailscale0" ];
  };

  # Obsidian LiveSync (native CouchDB)
  services.obsidian-livesync.enable = true;
  services.obsidian-livesync.dataDir = "/mnt/disk/couchdb";

  # llama.cpp 推論サーバー
  services.llama-server.enable = true;

  # Web Interface (SvelteKit + Bun)
  services.web-interface.enable = true;

  # Obsidian デイリーノートスケジューラー
  services.daily-note-scheduler.enable = true;

  # 外付けストレージ: systemd.mounts を使って静的ユニットを nix ストアに生成する
  systemd.mounts = [
    {
      description = "External storage /mnt/disk";
      what = "/dev/sda1";
      where = "/mnt/disk";
      type = "ext4";
      options = "nofail,x-systemd.device-timeout=30,noatime";
      wantedBy = [ "local-fs.target" ];
    }
    {
      description = "External storage /mnt/2disk";
      what = "/dev/sda2";
      where = "/mnt/2disk";
      type = "ext4";
      options = "nofail,x-systemd.device-timeout=30,noatime";
      wantedBy = [ "local-fs.target" ];
    }
  ];

  # ジャーナルを HDD に永続保存 (14日間保持)
  systemd.services.journal-persist = {
    description = "Persist journal to HDD in real-time";
    after    = [ "mnt-disk.mount" "systemd-journald.service" ];
    requires = [ "mnt-disk.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type       = "simple";
      User       = "root";
      Restart    = "on-failure";
      RestartSec = "5s";
      ExecStart  = pkgs.writeShellScript "journal-persist" ''
        mkdir -p /mnt/disk/journal
        LOG="/mnt/disk/journal/boot-$(date +%Y%m%d-%H%M%S).log"
        find /mnt/disk/journal -name "boot-*.log" -mtime +14 -delete 2>/dev/null || true
        exec ${pkgs.systemd}/bin/journalctl -b -f --no-tail --output=short-iso >> "$LOG"
      '';
    };
  };

  # WiFi
  age.secrets.wifi-env = {
    file = ./secrets/wifi-env.age;
  };
  networking.wireless = {
    enable = true;
    secretsFile = config.age.secrets.wifi-env.path;
    networks."JCOM_RDGN".pskRaw = "ext:PSK_JCOM_RDGN";
  };

  # Cloudflare Tunnel (tc.bido.dev)
  age.secrets.cloudflared-token = {
    file = ./secrets/cloudflared-token.age;
  };

  environment.etc."cloudflared/config.yml".text = ''
    ingress:
      - hostname: obsidian.bido.dev
        service: http://localhost:5984
      - hostname: tc.bido.dev
        path: /reservation*
        service: http://localhost:5173
      - hostname: tc.bido.dev
        path: /studio-assignment*
        service: http://localhost:5174
      - hostname: tc.bido.dev
        service: http_status:404
      - service: http_status:404
  '';

  systemd.services.cloudflared = {
    description = "Cloudflare Tunnel";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.bash}/bin/sh -c 'exec ${pkgs.cloudflared}/bin/cloudflared --config /etc/cloudflared/config.yml --metrics 127.0.0.1:8082 tunnel --no-autoupdate --protocol http2 run --token \"$(cat ${config.age.secrets.cloudflared-token.path})\"'";
      Restart = "always";
      RestartSec = "10s";
    };
  };

  systemd.services.cloudflared-healthcheck = {
    description = "Cloudflare Tunnel connection health check";
    after = [ "cloudflared.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = let
        script = pkgs.writeShellScript "cloudflared-healthcheck" ''
          systemctl is-active --quiet cloudflared || exit 0
          CONNS=$(${pkgs.curl}/bin/curl -sf --max-time 3 http://127.0.0.1:8082/metrics 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep '^cloudflared_tunnel_ha_connections' \
            | ${pkgs.gawk}/bin/awk '{sum += $2} END {print sum+0}')
          if [ "''${CONNS:-0}" -eq 0 ]; then
            echo "cloudflared: no active tunnel connections, restarting"
            systemctl restart cloudflared
          fi
        '';
      in "${script}";
    };
  };

  systemd.timers.cloudflared-healthcheck = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };

  environment.systemPackages = with pkgs; [ bun git nodejs pnpm deno cloudflared ];

  programs.nix-ld.enable = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "rpi" ];
  };

  system.stateVersion = "24.11";
}
