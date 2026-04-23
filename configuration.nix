{ config, pkgs, lib, ... }:

{
  imports = [
    ./modules/obsidian-livesync.nix
    ./modules/obsidian-livesync-backup.nix
  ];

  networking.hostName = "nixpi";
  time.timeZone = "Asia/Tokyo";

  users.users.rpi = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
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

  # Docker
  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";

  # Obsidian LiveSync
  services.obsidian-livesync.enable = true;
  services.obsidian-livesync.dataDir = "/mnt/disk/couchdb";

  # Obsidian LiveSync バックアップ CLI
  services.obsidian-livesync-backup.enable = true;

  # 外付けストレージ: systemd.mounts を使って静的ユニットを nix ストアに生成する
  # fileSystems (fstab 経由) だと switch-to-configuration-ng がランタイム生成ユニットを
  # nix ストアで探して失敗するため、静的ユニットを直接生成する方式に変更
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
  # Tunnel ID: 6f0e6b36-3a09-4904-b769-6e5ebce6d2c1
  age.secrets.cloudflared-token = {
    file = ./secrets/cloudflared-token.age;
  };

  # ingressルール設定 (config.yml)
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
      ExecStart = "${pkgs.bash}/bin/sh -c 'exec ${pkgs.cloudflared}/bin/cloudflared --config /etc/cloudflared/config.yml tunnel --no-autoupdate run --token \"$(cat ${config.age.secrets.cloudflared-token.path})\"'";
      Restart = "always";
      RestartSec = "10s";
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
