{ config, pkgs, lib, ... }:

{
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

  security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "24.11";
}
