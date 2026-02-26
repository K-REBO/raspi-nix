#!/usr/bin/env bash
# Obsidian Self-Hosted LiveSync 初回セットアップウィザード
#
# このスクリプトはホストマシン (x86_64) で実行してください
#
# セットアップフロー:
#   1. 前提条件チェック
#   2. 初回デプロイ (クロスビルド + deploy-rs)
#   3. Raspberry Pi で init.sh 実行 (SSH 経由)
#   4. 設定ファイルの更新 (サービス有効化)
#   5. 再デプロイ (サービス起動)

set -euo pipefail

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# スクリプトのディレクトリ
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_HOSTNAME="${PI_HOSTNAME:-nixpi}"
PI_USER="${PI_USER:-rpi}"

# ヘルパー関数
info() {
    echo -e "${BLUE}ℹ️  [INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}✅ [SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠️  [WARNING]${NC} $1"
}

error() {
    echo -e "${RED}❌ [ERROR]${NC} $1"
    exit 1
}

prompt() {
    echo -e "${CYAN}❓ [PROMPT]${NC} $1"
}

header() {
    echo
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# 前提条件チェック
check_prerequisites() {
    header "前提条件チェック"

    # Nix が利用可能か
    if ! command -v nix &> /dev/null; then
        error "Nix が見つかりません。https://nixos.org/download.html からインストールしてください。"
    fi
    success "Nix が見つかりました"

    # flake が有効か
    if ! nix flake show &> /dev/null; then
        error "flake が無効か、flake.nix に問題があります。"
    fi
    success "flake.nix が有効です"

    # SSH 接続を確認
    info "Raspberry Pi への SSH 接続を確認しています..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${PI_USER}@${PI_HOSTNAME}" "exit" &> /dev/null; then
        warning "Raspberry Pi に接続できません。"
        warning "事前に SSH 公開鍵認証を設定してください:"
        echo "  ssh-copy-id ${PI_USER}@${PI_HOSTNAME}"
        echo
        prompt "SSH 設定が完了したら Enter を押してください..."
        read -r

        # 再確認
        if ! ssh -o ConnectTimeout=5 "${PI_USER}@${PI_HOSTNAME}" "exit"; then
            error "Raspberry Pi に接続できません。セットアップを中断します。"
        fi
    fi
    success "Raspberry Pi に接続できました (${PI_USER}@${PI_HOSTNAME})"

    echo
}

# 初回デプロイ
initial_deploy() {
    header "ステップ 1/5: 初回デプロイ"

    info "Raspberry Pi に基本設定をデプロイします..."
    info "この処理には数分かかる場合があります。"
    echo

    if nix run github:serokell/deploy-rs -- ".#${PI_HOSTNAME}"; then
        success "初回デプロイが完了しました"
    else
        error "デプロイに失敗しました。エラーを確認してください。"
    fi

    echo
}

# リポジトリを Raspberry Pi にコピー
copy_repo_to_pi() {
    header "ステップ 2/5: リポジトリを Raspberry Pi にコピー"

    info "リポジトリを Raspberry Pi にコピーしています..."

    # リモートディレクトリを作成
    ssh "${PI_USER}@${PI_HOSTNAME}" "mkdir -p ~/projects"

    # rsync でコピー
    if rsync -avz --exclude '.git' --exclude '.claude' --exclude 'result' \
        "${SCRIPT_DIR}/" "${PI_USER}@${PI_HOSTNAME}:~/projects/raspi-nix/"; then
        success "リポジトリをコピーしました"
    else
        error "リポジトリのコピーに失敗しました"
    fi

    echo
}

# Raspberry Pi で init.sh を実行
run_init_on_pi() {
    header "ステップ 3/5: Raspberry Pi で初期設定"

    info "Raspberry Pi で init.sh を実行します..."
    info "対話的な入力が必要です (CouchDB パスワードなど)"
    echo

    prompt "準備ができたら Enter を押してください..."
    read -r

    # SSH 経由で init.sh を実行
    if ssh -t "${PI_USER}@${PI_HOSTNAME}" "cd ~/projects/raspi-nix && chmod +x init.sh && ./init.sh"; then
        success "init.sh が正常に完了しました"
    else
        error "init.sh の実行に失敗しました"
    fi

    echo
}

# 設定ファイルを同期
sync_config_from_pi() {
    header "ステップ 4/5: 設定ファイルの同期"

    info "Raspberry Pi から設定ファイルを取得しています..."

    # secrets/ と modules/ を同期
    rsync -avz "${PI_USER}@${PI_HOSTNAME}:~/projects/raspi-nix/secrets/" "${SCRIPT_DIR}/secrets/"
    rsync -avz "${PI_USER}@${PI_HOSTNAME}:~/projects/raspi-nix/modules/" "${SCRIPT_DIR}/modules/"

    success "設定ファイルを同期しました"
    echo
}

# サービスを有効化
enable_services() {
    header "ステップ 5/5: サービスの有効化"

    info "configuration.nix でサービスを有効化しています..."

    # configuration.nix を編集
    sed -i 's/services.obsidian-livesync.enable = false;/services.obsidian-livesync.enable = true;/' "${SCRIPT_DIR}/configuration.nix"
    sed -i 's/services.obsidian-tunnel.enable = false;/services.obsidian-tunnel.enable = true;/' "${SCRIPT_DIR}/configuration.nix"

    success "サービスを有効化しました"
    echo
}

# 最終デプロイ
final_deploy() {
    header "最終デプロイ"

    info "サービスを起動するために再デプロイします..."
    info "この処理には数分かかる場合があります。"
    echo

    if nix run github:serokell/deploy-rs -- ".#${PI_HOSTNAME}"; then
        success "最終デプロイが完了しました"
    else
        error "デプロイに失敗しました"
    fi

    echo
}

# 完了メッセージ
show_completion() {
    header "セットアップ完了! 🎉"

    echo -e "${GREEN}${BOLD}Obsidian Self-Hosted LiveSync のセットアップが完了しました!${NC}"
    echo
    echo "次のステップ:"
    echo
    echo "【1】サービスの確認:"
    echo "  ssh ${PI_USER}@${PI_HOSTNAME}"
    echo "  docker ps | grep obsidian-livesync"
    echo "  systemctl status cloudflared-tunnel-*"
    echo
    echo "【2】外部アクセステスト:"
    echo "  curl https://obsidian.bido.dev"
    echo
    echo "【3】Obsidian プラグイン設定:"
    echo "  - Community Plugins から 'Self-hosted LiveSync' をインストール"
    echo "  - Remote Database URL: https://obsidian.bido.dev"
    echo "  - Username/Password: init.sh で設定した値"
    echo
    echo "詳細は README.md を参照してください。"
    echo
}

# メイン処理
main() {
    clear
    echo
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                                                    ║${NC}"
    echo -e "${BOLD}${CYAN}║   Obsidian Self-Hosted LiveSync Setup Wizard      ║${NC}"
    echo -e "${BOLD}${CYAN}║                                                    ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════╝${NC}"
    echo

    info "このウィザードは Raspberry Pi に Obsidian LiveSync をセットアップします"
    info "処理には 10-15 分程度かかります"
    echo

    prompt "続行しますか? (y/N): "
    read -r CONTINUE
    if [[ ! "${CONTINUE}" =~ ^[Yy]$ ]]; then
        info "セットアップを中断しました"
        exit 0
    fi

    check_prerequisites
    initial_deploy
    copy_repo_to_pi
    run_init_on_pi
    sync_config_from_pi
    enable_services
    final_deploy
    show_completion
}

# スクリプト実行
main "$@"
