{
  description = "NixOS configuration for Raspberry Pi 4B";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    deploy-rs.url = "github:serokell/deploy-rs";
    agenix.url = "github:ryantm/agenix";
  };

  outputs = { self, nixpkgs, deploy-rs, agenix }: {
    nixosConfigurations.nixpi = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
        ./configuration.nix
        agenix.nixosModules.default
        {
          nixpkgs.buildPlatform = "x86_64-linux";
        }
      ];
    };

    # deploy-rs 設定
    deploy.nodes.nixpi = {
      hostname = "nixpi";
      profiles.system = {
        user = "root";
        sshUser = "rpi";
        path = deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.nixpi;
      };
    };

    # SDイメージビルド用
    packages.x86_64-linux.sdImage = self.nixosConfigurations.nixpi.config.system.build.sdImage;

    # deploy-rs チェック
    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
