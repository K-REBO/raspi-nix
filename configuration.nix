{ config, pkgs, lib, ... }:

{
  imports = [
    ./modules/obsidian-livesync.nix
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

  # sshdをOOMキラーから保護（メモリ逼迫時もSSH接続を維持するため）
  systemd.services.sshd.serviceConfig.OOMScoreAdjust = -500;

  security.sudo.wheelNeedsPassword = false;

  # Tailscale VPN
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
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

  # 外付けストレージ: SD カード保護のため書き込み頻度の高いデータを配置
  # nofail: デバイス不在でも起動継続
  # x-systemd.device-timeout=5: デバイス検出を最大5秒待つ（タイムアウト後は諦めて起動）
  fileSystems."/mnt/disk" = {
    device  = "/dev/sda1";
    fsType  = "ext4";
    options = [
      "nofail"
      "x-systemd.device-timeout=5"
      "noatime"
    ];
  };

  fileSystems."/mnt/2disk" = {
    device  = "/dev/sda2";
    fsType  = "ext4";
    options = [
      "nofail"
      "x-systemd.device-timeout=5"
      "noatime"
    ];
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

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "rpi" ];
  };

  system.stateVersion = "24.11";
}
