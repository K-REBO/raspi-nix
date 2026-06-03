{ config, pkgs, lib, ... }:

let
  cfg = config.services.web-interface;

  # bun で SvelteKit アプリをビルド
  # 初回: outputHash を lib.fakeHash にして nix build を実行し、出力されたハッシュに差し替える
  webBuild = pkgs.stdenv.mkDerivation {
    name = "web-interface";
    src = ../apps/web_interface;
    nativeBuildInputs = [ pkgs.bun pkgs.git ];
    outputHashMode = "recursive";
    # ソース変更後は `nix build .#nixosConfigurations.nixpi.config.system.build.toplevel` を
    # 実行して新しいハッシュに更新すること
    outputHash = "sha256-u3iigo+/jELBHA6vYiDdBInjdu6QptIJJO4/+SshG/c=";
    buildPhase = ''
      export HOME=$(mktemp -d)
      bun install --frozen-lockfile
      bun run build
    '';
    installPhase = ''
      mkdir -p $out
      cp -r build/* $out/
      cp package.json $out/
    '';
  };
in
{
  options.services.web-interface = {
    enable = lib.mkEnableOption "Web Interface (SvelteKit + Bun)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "バインドポート (localhost のみ)";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/disk/web-interface-data";
      description = "永続データの保存先 (HDD)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "rpi";
    };
  };

  config = lib.mkIf cfg.enable {
    # シークレット (rpi グループに読み取り許可)
    age.secrets.web-interface-env = {
      file = ../secrets/web-interface-env.age;
      mode = "0440";
      owner = "root";
      group = cfg.user;
    };

    # HDD データディレクトリ
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 ${cfg.user} ${cfg.user} -"
    ];

    # ネイティブ Bun サービス
    systemd.services.web-interface = {
      description = "Web Interface (SvelteKit + Bun)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "mnt-disk.mount" ];
      requires = [ "mnt-disk.mount" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        ExecStart = "${pkgs.bun}/bin/bun ${webBuild}/index.js";
        Restart = "on-failure";
        RestartSec = "10s";
        EnvironmentFile = config.age.secrets.web-interface-env.path;
        Environment = [
          "PORT=${toString cfg.port}"
          "HOST=0.0.0.0"
          "NODE_ENV=production"
          "DATA_DIR=${cfg.dataDir}"
          "HOME=/home/${cfg.user}"
          "PATH=/run/current-system/sw/bin:/home/${cfg.user}/.local/bin"
          "SCHEDULER_CMD=/run/current-system/sw/bin/daily-note-scheduler"
          "VAULT_CACHE_DIR=/mnt/2disk/daily-note-scheduler"
        ];
      };
    };
  };
}
