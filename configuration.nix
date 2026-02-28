{ config, pkgs, lib, ... }:

{
  # Raspberry Pi 4B 用 NixOS 設定

  # モジュールのインポート
  imports = [
    (if builtins.pathExists ./configuration.local.nix then ./configuration.local.nix else {})
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
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHurSJOCksQe93WR+fEYP9MiyJXNcnrz58hG0mRZOMHM bido@nixos"
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

  # 汎用的な動的リンクバイナリをサポート (Claude Code など)
  programs.nix-ld.enable = true;

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
    options = [ "defaults" "noatime" "nofail" ];
  };

  # データ保管用パーティション (~1.5TB)
  fileSystems."/mnt/data" = {
    device = "/dev/disk/by-uuid/60554cf5-4654-4cef-bca5-4524c6997636";
    fsType = "ext4";
    options = [ "defaults" "noatime" "nofail" ];
  };

  # /var をHDDにバインドマウント
  fileSystems."/var" = {
    device = "/mnt/hdd/var";
    fsType = "none";
    options = [ "bind" "nofail" ];
    depends = [ "/mnt/hdd" ];
  };

  # /home をHDDにバインドマウント
  fileSystems."/home" = {
    device = "/mnt/hdd/home";
    fsType = "none";
    options = [ "bind" "nofail" ];
    depends = [ "/mnt/hdd" ];
  };

  # ===========================================
  # Nix 設定
  # ===========================================
  nix.settings = {
    # 実験的機能を有効化
    experimental-features = [ "nix-command" "flakes" ];

    # バイナリキャッシュの設定
    substituters = [
      "https://cache.nixos.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];

    # セキュリティ: 署名検証を有効化
    require-sigs = true;  # false から変更

    # 信頼されたユーザー (署名なしローカルビルドを許可)
    trusted-users = [ "root" "@wheel" ];

    # Raspberry Pi 4B の最適化 (4コア、4GBメモリ)
    max-jobs = 2;  # メモリ不足を防ぐため制限
    cores = 2;     # 各ジョブで2コア使用

    # ビルドディレクトリ (既存設定を維持)
    build-dir = "/tmp";

    # ストア最適化
    auto-optimise-store = true;
  };

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

  # ===========================================
  # MOTD (Message of the Day) 設定
  # ===========================================

  # SSH ログイン時に表示される MOTD スクリプト
  environment.etc."profile.d/motd.sh" = {
    text = ''
      # SSH 接続時のみ表示 (ローカルログインでは表示しない)
      if [ -n "$SSH_CONNECTION" ] && [ -z "$MOTD_SHOWN" ]; then
        export MOTD_SHOWN=1

        # システム情報を取得
        HOSTNAME=$(hostname)
        BUILD_DATE=$(date -r /run/current-system '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Unknown")
        UPTIME=$(uptime -p)
        NIXOS_VERSION=$(nixos-version 2>/dev/null || echo "NixOS")

        # CPU温度 (Raspberry Pi)
        CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f°C", $1/1000}' || echo "N/A")

        # メモリ使用量
        MEM_INFO=$(free -h | awk '/^Mem:/ {printf "%s / %s", $3, $2}')

        echo ""
        echo "╔════════════════════════════════════════════════╗"
        echo "║         Welcome to NixOS Raspberry Pi          ║"
        echo "╚════════════════════════════════════════════════╝"
        echo ""
        echo "  Hostname:     $HOSTNAME"
        echo "  NixOS:        $NIXOS_VERSION"
        echo "  Last build:   $BUILD_DATE"
        echo "  Uptime:       $UPTIME"
        echo "  CPU temp:     $CPU_TEMP"
        echo "  Memory:       $MEM_INFO"
        echo ""
      fi
    '';
    mode = "0555";
  };
  security.sudo.wheelNeedsPassword = false;

  # システムバージョン
  system.stateVersion = "24.11";
}
