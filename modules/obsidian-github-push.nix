{ config, pkgs, lib, ... }:

let
  cfg = config.services.obsidian-github-push;
  git = "${pkgs.git}/bin/git";
  ssh = "${pkgs.openssh}/bin/ssh";
in
{
  options.services.obsidian-github-push = {
    enable = lib.mkEnableOption "Obsidian vault を GitHub にプッシュするサービス";

    vaultDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/2disk/obsidian-backup";
      description = "obsidian-vault-sync の出力ディレクトリ";
    };

    remoteUrl = lib.mkOption {
      type = lib.types.str;
      example = "git@github.com:user/obsidian-vault.git";
      description = "GitHub リモート URL (SSH 形式)";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "プッシュ先ブランチ名";
    };

    gitUserName = lib.mkOption {
      type = lib.types.str;
      default = "Bido Nakamura";
    };

    gitUserEmail = lib.mkOption {
      type = lib.types.str;
      default = "58938944+K-REBO@users.noreply.github.com";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets.github-deploy-key = {
      file = ../secrets/github-deploy-key.age;
      mode = "0400";
      owner = "rpi";
    };

    # obsidian-vault-sync 完了後に github-push を起動
    systemd.services.obsidian-vault-sync = {
      wants = [ "obsidian-github-push.service" ];
    };

    systemd.services.obsidian-github-push = {
      description = "Obsidian vault GitHub push";
      after = [ "obsidian-vault-sync.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "rpi";
        ExecStart = pkgs.writeShellScript "obsidian-github-push" ''
          set -euo pipefail

          VAULT_DIR="${cfg.vaultDir}"
          SSH_KEY="${config.age.secrets.github-deploy-key.path}"

          export GIT_SSH_COMMAND="${ssh} -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

          if [ ! -d "$VAULT_DIR/.git" ]; then
            echo "git リポジトリを初期化: $VAULT_DIR"
            ${git} -C "$VAULT_DIR" init -b "${cfg.branch}"
            ${git} -C "$VAULT_DIR" remote add origin "${cfg.remoteUrl}"
          fi

          ${git} -C "$VAULT_DIR" config user.name "${cfg.gitUserName}"
          ${git} -C "$VAULT_DIR" config user.email "${cfg.gitUserEmail}"
          ${git} -C "$VAULT_DIR" add -A

          if ${git} -C "$VAULT_DIR" diff --cached --quiet; then
            echo "変更なし、スキップ"
            exit 0
          fi

          TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
          ${git} -C "$VAULT_DIR" commit -m "vault backup: $TIMESTAMP"
          ${git} -C "$VAULT_DIR" push origin HEAD:"${cfg.branch}"
          echo "プッシュ完了: $TIMESTAMP"
        '';
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # 初回セットアップ用ヘルパー
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "obsidian-github-init" ''
        set -euo pipefail
        VAULT_DIR="${cfg.vaultDir}"
        SSH_KEY="${config.age.secrets.github-deploy-key.path}"
        export GIT_SSH_COMMAND="${ssh} -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

        if [ ! -d "$VAULT_DIR" ]; then
          echo "vault ディレクトリが存在しません: $VAULT_DIR" >&2
          echo "先に obsidian-vault-sync を実行してください。" >&2
          exit 1
        fi

        if [ ! -d "$VAULT_DIR/.git" ]; then
          ${git} -C "$VAULT_DIR" init -b "${cfg.branch}"
          ${git} -C "$VAULT_DIR" remote add origin "${cfg.remoteUrl}"
          echo "初期化完了"
        else
          echo "既に git リポジトリとして初期化済み"
          ${git} -C "$VAULT_DIR" remote -v
        fi

        echo "SSH 接続テスト..."
        ${ssh} -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true

        ${git} -C "$VAULT_DIR" config user.name "${cfg.gitUserName}"
        ${git} -C "$VAULT_DIR" config user.email "${cfg.gitUserEmail}"
        ${git} -C "$VAULT_DIR" add -A

        if ${git} -C "$VAULT_DIR" diff --cached --quiet; then
          echo "変更なし (vault が空の可能性)"
        else
          ${git} -C "$VAULT_DIR" commit -m "vault backup: initial"
          ${git} -C "$VAULT_DIR" push -u origin "${cfg.branch}"
          echo "初回プッシュ完了"
        fi
      '')
    ];
  };
}
