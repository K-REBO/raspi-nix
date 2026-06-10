let
  userKey   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGvI3ILtsXArrQgy59WCJAsrGxS52qm82Sq/0vYYzicS bido@nixos";
  systemKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAw5N69TZAM54ymUO/stJUe61v7GyRZnrSP4Gb+DXm8 root@nixpi";
  allKeys   = [ userKey systemKey ];
in
{
  "secrets/couchdb-env.age".publicKeys       = allKeys;
  "secrets/cloudflared-token.age".publicKeys = allKeys;
  "secrets/wifi-env.age".publicKeys          = allKeys;
  "secrets/web-interface-env.age".publicKeys  = allKeys;
  "secrets/discord.age".publicKeys           = allKeys;
  "secrets/discord-webhook.age".publicKeys   = allKeys;
  "secrets/github-deploy-key.age".publicKeys = allKeys;
  "secrets/playit-secret.age".publicKeys     = allKeys;
  "secrets/vault-env.age".publicKeys         = allKeys;
  "secrets/hisaki-env.age".publicKeys        = allKeys;
}
