# このファイルは setup.sh によって自動生成されます
# 手動で編集しないでください

let
  # ユーザーSSH公開鍵
  userKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHurSJOCksQe93WR+fEYP9MiyJXNcnrz58hG0mRZOMHM";

  # システムSSH ホストキー (setup.sh で自動設定)
  systemKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIENLj6dfUbzh6GcOA6STApoVdWLv2ZMLlILBLiH1Zx5d";

  # 全ての許可キー
  allKeys = [ userKey systemKey ];
in
{
  # CouchDB 環境変数
  "couchdb-env.age".publicKeys = allKeys;

  # Cloudflare Tunnel 認証情報
  "cloudflared-creds.age".publicKeys = allKeys;

  # Cloudflare Tunnel Token
  "cloudflared-token.age".publicKeys = allKeys;
}
