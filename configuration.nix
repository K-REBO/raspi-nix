{ config, pkgs, lib, ... }:

{
  imports = [
    ./modules/obsidian-livesync.nix
    ./modules/cloudflared.nix
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

  # Obsidian LiveSync / Cloudflared (secrets 設定後に enable = true にする)
  services.obsidian-livesync.enable = false;
  services.obsidian-tunnel.enable = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "24.11";
}
