#!/usr/bin/env bash
# Obsidian Self-Hosted LiveSync セットアップスクリプト
# このスクリプトは Raspberry Pi 上で実行してください

set -euo pipefail

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# スクリプトのディレクトリ
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="${SCRIPT_DIR}/secrets"

# ヘルパー関数
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

prompt() {
    echo -e "${GREEN}[PROMPT]${NC} $1"
}

# 前提条件チェック
check_prerequisites() {
    info "前提条件をチェックしています..."

    # Nix が利用可能か
    if ! command -v nix &> /dev/null; then
        error "Nix が見つかりません。NixOS 環境で実行してください。"
    fi

    # age が利用可能か
    if ! command -v age &> /dev/null; then
        error "age が見つかりません。まず基本設定をデプロイしてください。"
    fi

    # cloudflared が利用可能か
    if ! command -v cloudflared &> /dev/null; then
        error "cloudflared が見つかりません。まず基本設定をデプロイしてください。"
    fi

    # jq が利用可能か
    if ! command -v jq &> /dev/null; then
        error "jq が見つかりません。まず基本設定をデプロイしてください。"
    fi

    # SSH ホストキーが存在するか
    if [ ! -f /etc/ssh/ssh_host_ed25519_key.pub ]; then
        error "SSH ホストキーが見つかりません。"
    fi

    success "全ての前提条件を満たしています。"
}

# ユーザー入力の収集
collect_user_input() {
    info "CouchDB の設定を入力してください..."
    echo

    # CouchDB 管理者ユーザー名
    prompt "CouchDB 管理者ユーザー名 (デフォルト: admin):"
    read -r COUCHDB_USER
    COUCHDB_USER="${COUCHDB_USER:-admin}"

    # CouchDB 管理者パスワード
    while true; do
        prompt "CouchDB 管理者パスワード (最低12文字):"
        read -rs COUCHDB_PASSWORD
        echo
        prompt "パスワードを再入力してください:"
        read -rs COUCHDB_PASSWORD_CONFIRM
        echo

        if [ "${COUCHDB_PASSWORD}" != "${COUCHDB_PASSWORD_CONFIRM}" ]; then
            warning "パスワードが一致しません。再入力してください。"
            continue
        fi

        if [ ${#COUCHDB_PASSWORD} -lt 12 ]; then
            warning "パスワードは最低12文字必要です。"
            continue
        fi

        break
    done

    # CouchDB データベース名
    prompt "CouchDB データベース名 (デフォルト: obsidian):"
    read -r COUCHDB_DATABASE
    COUCHDB_DATABASE="${COUCHDB_DATABASE:-obsidian}"

    # データ保存パス
    prompt "データ保存パス (デフォルト: /mnt/data/couchdb):"
    read -r DATA_DIR
    DATA_DIR="${DATA_DIR:-/mnt/data/couchdb}"

    echo
    success "設定を収集しました:"
    echo "  ユーザー名: ${COUCHDB_USER}"
    echo "  データベース名: ${COUCHDB_DATABASE}"
    echo "  データパス: ${DATA_DIR}"
    echo
}

# Cloudflare Tunnel の作成
create_cloudflare_tunnel() {
    info "Cloudflare Tunnel を作成します..."
    echo

    TUNNEL_NAME="obsidian-livesync-$(date +%s)"

    warning "ブラウザで Cloudflare 認証を行います。"
    warning "ヘッドレス環境の場合、SSH ポートフォワーディングを使用してください:"
    warning "  ssh -L 8080:localhost:8080 rpi@nixpi"
    echo

    prompt "Enterキーを押して認証を開始してください..."
    read -r

    # Cloudflare 認証
    if ! cloudflared tunnel login; then
        error "Cloudflare 認証に失敗しました。"
    fi

    success "Cloudflare 認証が完了しました。"
    echo

    # Tunnel 作成
    info "Tunnel '${TUNNEL_NAME}' を作成しています..."
    if ! cloudflared tunnel create "${TUNNEL_NAME}"; then
        error "Tunnel の作成に失敗しました。"
    fi

    # Tunnel ID を取得
    TUNNEL_ID=$(cloudflared tunnel list | grep "${TUNNEL_NAME}" | awk '{print $1}')
    if [ -z "${TUNNEL_ID}" ]; then
        error "Tunnel ID の取得に失敗しました。"
    fi

    success "Tunnel が作成されました:"
    echo "  名前: ${TUNNEL_NAME}"
    echo "  ID: ${TUNNEL_ID}"
    echo

    # Credentials ファイルのパスを取得
    CREDS_FILE="${HOME}/.cloudflared/${TUNNEL_ID}.json"
    if [ ! -f "${CREDS_FILE}" ]; then
        error "Credentials ファイルが見つかりません: ${CREDS_FILE}"
    fi

    success "Credentials ファイルを取得しました: ${CREDS_FILE}"
}

# シークレットの暗号化
encrypt_secrets() {
    info "シークレットを暗号化しています..."
    echo

    # システム SSH ホストキーの取得
    SYSTEM_HOST_KEY=$(sudo cat /etc/ssh/ssh_host_ed25519_key.pub)
    if [ -z "${SYSTEM_HOST_KEY}" ]; then
        error "システム SSH ホストキーの取得に失敗しました。"
    fi

    success "システム SSH ホストキーを取得しました。"

    # secrets.nix の更新
    info "secrets.nix を更新しています..."
    cat > "${SECRETS_DIR}/secrets.nix" <<EOF
# このファイルは setup.sh によって自動生成されました
# 手動編集は推奨されません

let
  # ユーザーSSH公開鍵
  userKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHurSJOCksQe93WR+fEYP9MiyJXNcnrz58hG0mRZOMHM";

  # システムSSH ホストキー
  systemKey = "${SYSTEM_HOST_KEY}";

  # 全ての許可キー
  allKeys = [ userKey systemKey ];
in
{
  # CouchDB 環境変数
  "couchdb-env.age".publicKeys = allKeys;

  # Cloudflare Tunnel 認証情報
  "cloudflared-creds.age".publicKeys = allKeys;
}
EOF

    success "secrets.nix を更新しました。"

    # CouchDB 環境変数の暗号化
    info "CouchDB 環境変数を暗号化しています..."
    TEMP_ENV_FILE=$(mktemp)
    cat > "${TEMP_ENV_FILE}" <<EOF
COUCHDB_USER=${COUCHDB_USER}
COUCHDB_PASSWORD=${COUCHDB_PASSWORD}
COUCHDB_DATABASE=${COUCHDB_DATABASE}
EOF

    # age で暗号化
    if ! cat "${TEMP_ENV_FILE}" | age -r "${SYSTEM_HOST_KEY}" -o "${SECRETS_DIR}/couchdb-env.age"; then
        rm -f "${TEMP_ENV_FILE}"
        error "CouchDB 環境変数の暗号化に失敗しました。"
    fi

    rm -f "${TEMP_ENV_FILE}"
    success "CouchDB 環境変数を暗号化しました。"

    # Cloudflare Credentials の暗号化
    info "Cloudflare Credentials を暗号化しています..."
    if ! age -r "${SYSTEM_HOST_KEY}" -o "${SECRETS_DIR}/cloudflared-creds.age" "${CREDS_FILE}"; then
        error "Cloudflare Credentials の暗号化に失敗しました。"
    fi

    success "Cloudflare Credentials を暗号化しました。"
    echo
}

# 設定ファイルの更新
update_config_files() {
    info "設定ファイルを更新しています..."
    echo

    # cloudflared.nix の TUNNEL_ID を更新
    if grep -q "TUNNEL_ID_PLACEHOLDER" "${SCRIPT_DIR}/modules/cloudflared.nix"; then
        sed -i "s/TUNNEL_ID_PLACEHOLDER/${TUNNEL_ID}/g" "${SCRIPT_DIR}/modules/cloudflared.nix"
        success "cloudflared.nix の Tunnel ID を更新しました。"
    else
        warning "cloudflared.nix の Tunnel ID は既に設定されています。"
    fi

    # データパスがデフォルトと異なる場合、obsidian-livesync.nix を更新
    if [ "${DATA_DIR}" != "/mnt/data/couchdb" ]; then
        # この場合は configuration.nix で上書きが必要
        warning "データパスがデフォルトと異なります。"
        warning "configuration.nix に以下を追加してください:"
        echo "  services.obsidian-livesync.dataDir = \"${DATA_DIR}\";"
        echo
    fi
}

# DNS 設定の指示
show_dns_instructions() {
    info "DNS 設定が必要です。"
    echo
    echo "以下のいずれかの方法で CNAME レコードを追加してください:"
    echo
    echo "【方法1】Cloudflare ダッシュボード:"
    echo "  タイプ: CNAME"
    echo "  名前: obsidian"
    echo "  値: ${TUNNEL_ID}.cfargotunnel.com"
    echo "  TTL: Auto"
    echo
    echo "【方法2】自動設定 (推奨):"
    echo "  cloudflared tunnel route dns ${TUNNEL_ID} obsidian.bido.dev"
    echo

    prompt "自動設定を実行しますか? (y/N):"
    read -r AUTO_DNS

    if [[ "${AUTO_DNS}" =~ ^[Yy]$ ]]; then
        info "DNS レコードを自動設定しています..."
        if cloudflared tunnel route dns "${TUNNEL_ID}" obsidian.bido.dev; then
            success "DNS レコードを設定しました。"
        else
            warning "DNS レコードの自動設定に失敗しました。手動で設定してください。"
        fi
    else
        warning "DNS レコードを手動で設定してください。"
    fi
    echo
}

# NixOS リビルド
nixos_rebuild() {
    info "NixOS 設定を適用します。"
    echo

    prompt "nixos-rebuild switch を実行しますか? (y/N):"
    read -r DO_REBUILD

    if [[ "${DO_REBUILD}" =~ ^[Yy]$ ]]; then
        info "NixOS をリビルドしています (時間がかかる場合があります)..."
        if sudo nixos-rebuild switch --flake "${SCRIPT_DIR}#nixpi"; then
            success "NixOS のリビルドが完了しました。"
        else
            error "NixOS のリビルドに失敗しました。"
        fi
    else
        warning "後で手動で以下を実行してください:"
        echo "  cd ${SCRIPT_DIR}"
        echo "  sudo nixos-rebuild switch --flake .#nixpi"
    fi
    echo
}

# 検証手順の表示
show_verification_steps() {
    success "セットアップが完了しました!"
    echo
    info "以下のコマンドで動作を確認してください:"
    echo
    echo "【1】Docker コンテナの確認:"
    echo "  docker ps | grep obsidian-livesync"
    echo "  docker logs docker-obsidian-livesync"
    echo
    echo "【2】CouchDB ローカル接続テスト:"
    echo "  curl http://localhost:5984"
    echo "  curl -u ${COUCHDB_USER}:****** http://localhost:5984/_all_dbs"
    echo
    echo "【3】Cloudflare Tunnel の確認:"
    echo "  systemctl status cloudflared-tunnel-${TUNNEL_ID}"
    echo "  cloudflared tunnel info ${TUNNEL_ID}"
    echo
    echo "【4】外部アクセステスト (DNS反映後):"
    echo "  curl https://obsidian.bido.dev"
    echo "  curl -u ${COUCHDB_USER}:****** https://obsidian.bido.dev/_all_dbs"
    echo
    echo "【5】Obsidian プラグイン設定:"
    echo "  - Community Plugins から 'Self-hosted LiveSync' をインストール"
    echo "  - Remote Database URL: https://obsidian.bido.dev"
    echo "  - Username: ${COUCHDB_USER}"
    echo "  - Password: (setup時に設定したパスワード)"
    echo "  - Database name: ${COUCHDB_DATABASE}"
    echo
}

# メイン処理
main() {
    echo
    echo "=========================================="
    echo "  Obsidian Self-Hosted LiveSync Setup"
    echo "=========================================="
    echo

    check_prerequisites
    collect_user_input
    create_cloudflare_tunnel
    encrypt_secrets
    update_config_files
    show_dns_instructions
    nixos_rebuild
    show_verification_steps

    success "全ての処理が完了しました!"
}

# スクリプト実行
main
