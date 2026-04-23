{ config, pkgs, lib, ... }:

let
  cfg = config.services.obsidian-livesync-backup;
  node = "${pkgs.nodejs}/bin/node";
  git = "${pkgs.git}/bin/git";
  cliEntry = "${cfg.cliDir}/src/apps/cli/dist/index.cjs";
  cli = "${node} ${cliEntry} ${cfg.dbDir}";
in
{
  options.services.obsidian-livesync-backup = {
    enable = lib.mkEnableOption "Obsidian LiveSync CLI backup tool";

    cliDir = lib.mkOption {
      type = lib.types.str;
      default = "/opt/obsidian-livesync-cli";
      description = "obsidian-livesync リポジトリのクローン先";
    };

    dbDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/2disk/livesync-db";
      description = "CLI 用ローカル PouchDB ディレクトリ";
    };

    outputDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/2disk/obsidian-backup";
      description = "vault ファイルの出力先";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.cliDir}   0755 rpi rpi -"
    ];

    environment.systemPackages = [

      # Step 1: CLI のビルドと Setup URI の適用
      # 使い方: livesync-setup "obsidian://setuplivesync?settings=..."
      (pkgs.writeShellScriptBin "livesync-setup" ''
        set -euo pipefail
        if [ -z "''${1:-}" ]; then
          echo "使い方: livesync-setup <Setup-URI>"
          echo ""
          echo "Setup URI の取得方法:"
          echo "  Obsidian > コマンドパレット (Ctrl+P) > Copy setup URI"
          exit 1
        fi
        SETUP_URI="$1"

        mkdir -p "${cfg.dbDir}"

        echo "[1/3] リポジトリ取得..."
        if [ ! -d "${cfg.cliDir}/.git" ]; then
          ${git} clone https://github.com/vrtmrz/obsidian-livesync.git "${cfg.cliDir}"
        else
          ${git} -C "${cfg.cliDir}" pull
        fi

        echo "[2/3] CLI ビルド..."
        cd "${cfg.cliDir}"
        ${pkgs.nodejs}/bin/npm install --prefer-offline
        cd src/apps/cli
        ${pkgs.nodejs}/bin/npm run build

        echo "[3/3] 設定の初期化と Setup URI の適用..."
        ${node} "${cliEntry}" init-settings "${cfg.dbDir}/.livesync/settings.json"
        ${node} "${cliEntry}" "${cfg.dbDir}" setup "$SETUP_URI"

        echo ""
        echo "セットアップ完了。次を実行: livesync-sync"
      '')

      # Step 2: 同期とファイル展開（sync → mirror の2段階）
      # 使い方: livesync-sync
      (pkgs.writeShellScriptBin "livesync-sync" ''
        set -euo pipefail
        if [ ! -f "${cliEntry}" ]; then
          echo "CLI が未ビルドです。先に livesync-setup <Setup-URI> を実行してください。" >&2
          exit 1
        fi

        mkdir -p "${cfg.dbDir}" "${cfg.outputDir}"

        echo "[1/2] sync: リモート CouchDB → ローカル PouchDB"
        ${cli} --verbose sync
        SYNC_STATUS=$?

        if [ $SYNC_STATUS -ne 0 ]; then
          echo ""
          echo "sync が失敗しました (終了コード: $SYNC_STATUS)"
          echo "issue #846 の既知バグの可能性があります。"
          echo "生 JSON バックアップには livesync-dump を試してください。"
          exit $SYNC_STATUS
        fi

        echo ""
        echo "[2/2] mirror: ローカル PouchDB → ファイル (${cfg.outputDir})"
        mkdir -p "${cfg.outputDir}"
        ${cli} mirror "${cfg.outputDir}" ""

        echo ""
        echo "完了。ファイル出力先: ${cfg.outputDir}"
        echo "ファイル数: $(find ${cfg.outputDir} -type f | wc -l)"
      '')

      # デバッグ用: DB 内ファイル一覧
      (pkgs.writeShellScriptBin "livesync-ls" ''
        set -euo pipefail
        if [ ! -f "${cliEntry}" ]; then
          echo "CLI が未ビルドです。先に livesync-setup を実行してください。" >&2
          exit 1
        fi
        ${cli} ls "''${1:-}"
      '')

      # フォールバック: CouchDB 生 JSON ダンプ
      # sync が失敗した場合に使用
      # 使い方: livesync-dump (couchdb-env の認証情報を自動読み込み)
      (pkgs.writeShellScriptBin "livesync-dump" ''
        set -euo pipefail
        COUCHDB_ENV="${config.age.secrets.couchdb-env.path}"

        if [ ! -f "$COUCHDB_ENV" ]; then
          echo "couchdb-env シークレットが見つかりません: $COUCHDB_ENV" >&2
          exit 1
        fi

        # 認証情報を読み込む
        export $(grep -v '^#' "$COUCHDB_ENV" | xargs)
        USER="''${COUCHDB_USER:-admin}"
        PASS="''${COUCHDB_PASSWORD:-}"
        PORT="${toString config.services.obsidian-livesync.port}"

        OUT_DIR="${cfg.outputDir}/json-dump"
        mkdir -p "$OUT_DIR"
        TIMESTAMP=$(date +%Y%m%d-%H%M%S)
        OUT_FILE="$OUT_DIR/dump-$TIMESTAMP.json"

        echo "CouchDB からデータベース一覧を取得中..."
        DBS=$(${pkgs.curl}/bin/curl -s -u "$USER:$PASS" \
          "http://localhost:$PORT/_all_dbs" | \
          ${pkgs.jq}/bin/jq -r '.[]' | grep -v '^_')

        for DB in $DBS; do
          echo "  ダンプ中: $DB"
          ${pkgs.curl}/bin/curl -s -u "$USER:$PASS" \
            "http://localhost:$PORT/$DB/_all_docs?include_docs=true" \
            > "$OUT_DIR/dump-$TIMESTAMP-$DB.json"
        done

        echo ""
        echo "ダンプ完了。出力先: $OUT_DIR/"
        ls -lh "$OUT_DIR/dump-$TIMESTAMP"*.json
      '')
    ];
  };
}
