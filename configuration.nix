{ config, pkgs, lib, ... }:

{
  # Raspberry Pi 4B 用 NixOS 設定

  # モジュールのインポート
  imports = [
    ./modules/obsidian-livesync.nix
    ./modules/cloudflared.nix
  ];

  # Obsidian LiveSync サービスの有効化
  # 注: setup.sh を実行してシークレットを設定した後に true に変更してください
  services.obsidian-livesync.enable = false;
  services.obsidian-tunnel.enable = false;

  # ホスト名
  networking.hostName = "nixpi";

  # タイムゾーン
  time.timeZone = "Asia/Tokyo";

  # ユーザー設定
  users.users.rpi = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHurSJOCksQe93WR+fEYP9MiyJXNcnrz58hG0mRZOMHM"
    ];
  };

  # SSH設定（公開鍵認証のみ）
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ファイアウォール（SSH許可）
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    # Tailscale インターフェースを信頼
    trustedInterfaces = [ "tailscale0" ];
  };

  # Tailscale VPN
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";  # クライアントとサブネットルーター両方として動作
  };

  # Docker 有効化
  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";

  # WiFi設定
  # 注: WiFi パスワードは agenix で暗号化するか、ローカル設定ファイルに分離してください
  # 現在はコメントアウトしています (public リポジトリ用)
  # networking.wireless = {
  #   enable = true;
  #   networks = {
  #     "YOUR_SSID" = {
  #       psk = "YOUR_PASSWORD";  # ← 実際の環境では secrets で管理
  #     };
  #   };
  # };

  # ===========================================
  # SDカード負荷軽減設定
  # ===========================================

  # /tmp を tmpfs にマウント
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "50%";

  # journald をメモリ上で動作させる
  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=64M
  '';

  # swap を無効化（SDカードへの書き込み防止）
  swapDevices = [ ];

  # ===========================================
  # HDD マウント設定（SDカード負荷軽減）
  # ===========================================

  # OS用パーティション (400GB)
  fileSystems."/mnt/hdd" = {
    device = "/dev/disk/by-uuid/026d7d92-b4b2-4c8a-a78a-2263850fdfd1";
    fsType = "ext4";
    options = [ "defaults" "noatime" ];
  };

  # データ保管用パーティション (~1.5TB)
  fileSystems."/mnt/data" = {
    device = "/dev/disk/by-uuid/60554cf5-4654-4cef-bca5-4524c6997636";
    fsType = "ext4";
    options = [ "defaults" "noatime" ];
  };

  # /var をHDDにバインドマウント
  fileSystems."/var" = {
    device = "/mnt/hdd/var";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/mnt/hdd" ];
  };

  # /home をHDDにバインドマウント
  fileSystems."/home" = {
    device = "/mnt/hdd/home";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/mnt/hdd" ];
  };

  # Nix ビルドを tmpfs 上で実行（メモリに余裕がある場合）
  nix.settings.build-dir = "/tmp";

  # ローカルビルドの署名なしパスを受け入れる
  nix.settings.require-sigs = false;

  # Flakes と nix-command を有効化
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ===========================================
  # 基本パッケージ
  # ===========================================
  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    age           # agenix CLI
    cloudflared   # トンネル管理
    jq            # JSON処理
    # 注: claude-code は aarch64-linux (ARM64) では利用できません
    # 手動インストール方法: curl -fsSL https://claude.ai/install.sh | sh
  ];

  # sudo でパスワード不要（wheel グループ）
  security.sudo.wheelNeedsPassword = false;

  # システムバージョン
  system.stateVersion = "24.11";
}
