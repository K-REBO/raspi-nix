{
  description = "NixOS configuration for Raspberry Pi 4B";

  # プロジェクトレベルのキャッシュ設定
  nixConfig = {
    # バイナリキャッシュの設定
    extra-substituters = [
      "https://cache.nixos.org"
    ];

    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];

    # ビルド最適化 (x86_64 ホストマシン用)
    max-jobs = "auto";  # 全CPUコアを使用
    cores = 4;          # 各ジョブで4コアまで使用 (メモリに応じて調整)
  };

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
      hostname = "192.168.40.89";
      profiles.system = {
        user = "root";
        sshUser = "rpi";
        path = deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.nixpi;

        # リモートビルドを無効化 (x86_64 でクロスビルド)
        remoteBuild = true;

        # ターゲットが cache.nixos.org からダウンロード
        fastConnection = false;
      };
    };

    # SDイメージビルド用
    packages.x86_64-linux.sdImage = self.nixosConfigurations.nixpi.config.system.build.sdImage;

    # deploy-rs チェック
    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
