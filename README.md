# Raspberry Pi 4B NixOS Configuration

NixOS Raspberry Pi 4B の設定ファイルと Obsidian Self-Hosted LiveSync サーバーのセットアップ。

## 概要

- **OS**: NixOS 24.11
- **ハードウェア**: Raspberry Pi 4B (4GB RAM)
- **ストレージ**:
  - SD カード: OS (読み取り専用最適化)
  - HDD (1.8TB): データ保存 (`/mnt/hdd`, `/mnt/data`)
- **サービス**:
  - Obsidian Self-Hosted LiveSync (CouchDB)
  - Cloudflare Tunnel (外部アクセス用)
  - Tailscale VPN (プライベートネットワーク)

## 技術スタック

- **CouchDB**: Docker コンテナ (`oleduc/docker-obsidian-livesync-couchdb:latest`)
- **Cloudflared**: NixOS サービスモジュール
- **Tailscale**: VPN サービス
- **Agenix**: SSH鍵ベースのシークレット暗号化
- **deploy-rs**: クロスビルド & 自動デプロイ

## ローカル設定 (WiFi など)

このリポジトリは public にできるように、WiFi パスワードなどの機密情報はコメントアウトされています。実際に使用する際は、ローカル設定ファイルを作成してください:

### configuration.local.nix の作成

```bash
cat > configuration.local.nix <<'EOF'
{ config, pkgs, lib, ... }:
{
  # WiFi設定 (個人環境用)
  networking.wireless = {
    enable = true;
    networks = {
      "YOUR_SSID" = {
        psk = "YOUR_PASSWORD";
      };
    };
  };
}
EOF
```

### configuration.nix で読み込み

`configuration.nix` の `imports` セクションに追加:
```nix
imports = [
  ./modules/obsidian-livesync.nix
  ./modules/cloudflared.nix
  ./configuration.local.nix  # ← これを追加
];
```

**注意**: `configuration.local.nix` は `.gitignore` に含まれているため、git にコミットされません。

## セットアップ手順

### 簡単セットアップ (推奨)

初回セットアップウィザードを使用すると、全ての手順が自動化されます:

```bash
cd /home/bido/projects/raspi-nix
./setup.sh
```

ウィザードが以下を自動的に実行します:
1. ✅ 前提条件チェック
2. ✅ 初回デプロイ (クロスビルド)
3. ✅ リポジトリを Raspberry Pi にコピー
4. ✅ Raspberry Pi で初期設定 (SSH 経由で `init.sh` 実行)
5. ✅ 設定ファイルの同期
6. ✅ サービスの有効化
7. ✅ 最終デプロイ (サービス起動)

**所要時間**: 10-15分程度

---

### 手動セットアップ (上級者向け)

ウィザードを使わず手動でセットアップする場合:

#### ステップ1: ホストマシンで初回デプロイ

```bash
cd /home/bido/projects/raspi-nix
nix run github:serokell/deploy-rs -- .#nixpi
```

#### ステップ2: Raspberry Pi で初期設定

```bash
# SSH 接続
ssh rpi@nixpi

# リポジトリをコピー (ホストマシンから)
# または git clone

# 初期設定スクリプト実行
cd ~/projects/raspi-nix
./init.sh
```

`init.sh` は以下を実行します:
- CouchDB の設定 (ユーザー名、パスワード、データベース名)
- Cloudflare Tunnel の作成
- シークレットの暗号化 (agenix)
- 設定ファイルの更新 (Tunnel ID など)
- DNS レコードの設定

**ヘッドレス環境の場合**:
別のターミナルで SSH ポートフォワーディング:
```bash
ssh -L 8080:localhost:8080 rpi@nixpi
```

#### ステップ3: ホストマシンで設定を同期・有効化

```bash
# 設定ファイルを同期
rsync -avz rpi@nixpi:~/projects/raspi-nix/secrets/ ./secrets/
rsync -avz rpi@nixpi:~/projects/raspi-nix/modules/ ./modules/

# サービスを有効化 (configuration.nix を編集)
vim configuration.nix
# services.obsidian-livesync.enable = true;
# services.obsidian-tunnel.enable = true;

# 再デプロイ
nix run github:serokell/deploy-rs -- .#nixpi
```

### 検証

1. **Docker コンテナ確認**:
   ```bash
   docker ps | grep obsidian-livesync
   docker logs docker-obsidian-livesync
   ```

2. **CouchDB ローカル接続テスト**:
   ```bash
   curl http://localhost:5984
   curl -u admin:password http://localhost:5984/_all_dbs
   ```

3. **Cloudflare Tunnel 確認**:
   ```bash
   systemctl status cloudflared-tunnel-{TUNNEL_ID}
   cloudflared tunnel list
   ```

4. **外部アクセステスト** (DNS 反映後):
   ```bash
   curl https://obsidian.bido.dev
   curl -u admin:password https://obsidian.bido.dev/_all_dbs
   ```

5. **Obsidian プラグイン設定**:
   - Community Plugins から "Self-hosted LiveSync" をインストール
   - プラグイン設定:
     - Remote Database URL: `https://obsidian.bido.dev`
     - Username: (setup.sh で設定した値)
     - Password: (setup.sh で設定した値)
     - Database name: (setup.sh で設定した値)
   - Test Connection → 成功を確認
   - 同期を有効化

## ファイル構造

```
/home/bido/projects/raspi-nix/
├── flake.nix                      # Nix flake 設定 (agenix input含む)
├── flake.lock                     # 依存関係のロック
├── configuration.nix              # メイン NixOS 設定
├── modules/
│   ├── obsidian-livesync.nix     # CouchDB コンテナ設定
│   └── cloudflared.nix           # Cloudflare tunnel 設定
├── secrets/
│   ├── secrets.nix               # agenix シークレット定義
│   ├── couchdb-env.age           # 暗号化された CouchDB 環境変数
│   ├── cloudflared-creds.age     # 暗号化された tunnel credentials
│   └── .gitignore                # シークレットファイルを git から除外
├── setup.sh                      # 初回セットアップウィザード (ホストマシンで実行)
├── init.sh                       # 初期設定スクリプト (Raspberry Pi で実行)
└── README.md                     # このファイル
```

## メンテナンス

### パスワード変更

```bash
cd /home/bido/projects/raspi-nix/secrets
# 暗号化されたファイルを編集 (age で復号・再暗号化)
nix run github:ryantm/agenix -- -e couchdb-env.age
sudo systemctl restart docker-obsidian-livesync
```

### バックアップ

```bash
# CouchDB データ
sudo tar czf couchdb-backup-$(date +%Y%m%d).tar.gz /mnt/data/couchdb

# 設定全体
cd /home/bido/projects
tar czf raspi-nix-backup-$(date +%Y%m%d).tar.gz raspi-nix/
```

### アップデート

```bash
# Docker イメージ更新
docker pull docker.io/oleduc/docker-obsidian-livesync-couchdb:latest
sudo systemctl restart docker-obsidian-livesync

# NixOS 設定更新
cd /home/bido/projects/raspi-nix
nix flake update
sudo nixos-rebuild switch --flake .#nixpi
```

## トラブルシューティング

### コンテナが起動しない

- **シークレット復号確認**:
  ```bash
  ls -la /run/agenix/
  ```

- **データディレクトリ権限**:
  ```bash
  ls -la /mnt/data/couchdb
  ```

- **ログ確認**:
  ```bash
  journalctl -u docker-obsidian-livesync -n 50
  ```

### トンネルが接続しない

- **DNS 設定確認**:
  ```bash
  nslookup obsidian.bido.dev
  ```

- **Tunnel 状態**:
  ```bash
  cloudflared tunnel info {TUNNEL_ID}
  ```

- **ログ確認**:
  ```bash
  journalctl -u cloudflared-tunnel-{TUNNEL_ID} -n 50
  ```

### シークレットが復号できない

- **SSH 鍵確認**:
  ```bash
  ls -la ~/.ssh/id_ed25519*
  sudo ls -la /etc/ssh/ssh_host_ed25519_key*
  ```

- **手動復号テスト**:
  ```bash
  cd secrets
  nix run github:ryantm/agenix -- -d couchdb-env.age
  ```

### Claude Code のインストールエラー

**問題**: `curl -fsSL https://claude.ai/install.sh | sh` で以下のエラー:
```
Could not start dynamically linked executable
NixOS cannot run dynamically linked executables intended for generic linux environments
```

**原因**: NixOS は標準的な Linux とは異なるファイルシステム構造を持つため、汎用的な動的リンクバイナリを直接実行できません。

**解決策**:

Claude Code は ARM64 (aarch64-linux) では nixpkgs パッケージとして提供されていないため、以下のいずれかの方法を使用してください:

1. **ホストマシン (x86_64) で Claude Code を使用** (推奨)
   - Raspberry Pi へは SSH 経由でアクセス
   - ローカルの Claude Code から `ssh rpi@nixpi` で作業

2. **nix-ld を有効化して汎用バイナリをサポート**

   `configuration.nix` に以下を追加:
   ```nix
   programs.nix-ld.enable = true;
   ```

   その後、再デプロイして Claude Code を再インストール:
   ```bash
   curl -fsSL https://claude.ai/install.sh | sh
   ```

3. **Tailscale 経由でホストマシンから接続**
   - Tailscale で Raspberry Pi に接続
   - ホストマシンの Claude Code から SSH 経由で作業

## セキュリティ

- CouchDB ポートは localhost のみ公開 (`127.0.0.1:5984`)
- 外部アクセスは Cloudflare Tunnel 経由のみ (自動HTTPS, DDoS保護)
- 全てのシークレットは agenix で暗号化、実行時に `/run/agenix/` へ復号
- SSH 公開鍵認証のみ、パスワード認証は無効
- ファイアウォールで SSH ポート (22) のみ許可

## 参考資料

- [Agenix - NixOS Wiki](https://nixos.wiki/wiki/Agenix)
- [Cloudflared - NixOS Wiki](https://wiki.nixos.org/wiki/Cloudflared)
- [obsidian-livesync setup documentation](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md)
- [oleduc/docker-obsidian-livesync-couchdb](https://github.com/oleduc/docker-obsidian-livesync-couchdb)
