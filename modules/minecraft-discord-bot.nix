{ config, pkgs, lib, ... }:

let
  cfg = config.services.minecraft-discord-bot;

  python = pkgs.python3;

  # ログ監視スクリプト: プレイヤーのログイン/ログアウトをembedで通知
  logWatcherScript = pkgs.writeScript "mc-log-watcher.py" ''
    #!${python}/bin/python3
    import os, json, re, subprocess, urllib.request
    from datetime import datetime, timezone

    WEBHOOK_URL    = open(os.environ["DISCORD_WEBHOOK_FILE"]).read().strip()
    CONTAINER_NAME = "${cfg.containerName}"

    online_players = set()

    def players_field():
        if not online_players:
            return {"name": "現在のプレイヤー", "value": "*誰もいません*", "inline": False}
        names = "\n".join(f"・{p}" for p in sorted(online_players))
        return {"name": f"現在のプレイヤー ({len(online_players)}人)", "value": names, "inline": False}

    def send_embed(player, joined: bool):
        now = datetime.now(timezone.utc).isoformat()
        if joined:
            title = f"✅  {player} が参加しました"
            color = 0x57F287  # Discord green
        else:
            title = f"👋  {player} が退出しました"
            color = 0xED4245  # Discord red

        payload = {
            "embeds": [{
                "title":     title,
                "color":     color,
                "fields":    [players_field()],
                "footer":    {"text": "Minecraft Bedrock"},
                "timestamp": now,
            }]
        }
        data = json.dumps(payload).encode()
        req  = urllib.request.Request(WEBHOOK_URL, data, {"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req)
        except Exception as e:
            print(f"Webhook error: {e}", flush=True)

    proc = subprocess.Popen(
        ["${pkgs.docker}/bin/docker", "logs", "-f", "--tail=0", CONTAINER_NAME],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    print(f"Watching logs for container: {CONTAINER_NAME}", flush=True)

    for line in proc.stdout:
        line = line.rstrip()
        if m := re.search(r"Player connected: ([^,]+)", line):
            player = m.group(1).strip()
            online_players.add(player)
            send_embed(player, joined=True)
        elif m := re.search(r"Player disconnected: ([^,]+)", line):
            player = m.group(1).strip()
            online_players.discard(player)
            send_embed(player, joined=False)
  '';

in
{
  options.services.minecraft-discord-bot = {
    enable = lib.mkEnableOption "Minecraft Discord Webhook Bot";

    webhookSecretFile = lib.mkOption {
      type        = lib.types.path;
      description = "Discord Webhook URLが書かれたファイルのパス (agenixシークレット)";
    };

    containerName = lib.mkOption {
      type    = lib.types.str;
      default = "minecraft-bedrock";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.minecraft-discord-log-watcher = {
      description = "Minecraft Discord Log Watcher";
      after       = [ "docker-minecraft-bedrock.service" ];
      wantedBy    = [ "multi-user.target" ];
      environment.DISCORD_WEBHOOK_FILE = cfg.webhookSecretFile;
      serviceConfig = {
        ExecStart  = logWatcherScript;
        Restart    = "always";
        RestartSec = "5s";
        User       = "root";
      };
    };
  };
}
