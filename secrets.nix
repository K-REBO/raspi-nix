let
  userKey   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGvI3ILtsXArrQgy59WCJAsrGxS52qm82Sq/0vYYzicS bido@nixos";
  systemKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIENLj6dfUbzh6GcOA6STApoVdWLv2ZMLlILBLiH1Zx5d root@nixpi";
  allKeys   = [ userKey systemKey ];
in
{
  "secrets/couchdb-env.age".publicKeys       = allKeys;
  "secrets/cloudflared-token.age".publicKeys = allKeys;
  "secrets/wifi-env.age".publicKeys          = allKeys;
  "secrets/web-interface-env.age".publicKeys = allKeys;
  "secrets/hisaki-env.age".publicKeys        = allKeys;
}
