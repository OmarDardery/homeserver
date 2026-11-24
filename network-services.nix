{ pkgs, ... }:
let
  state = "/var/lib/homeserver/aiostreams";
  initAio = pkgs.writeShellScript "init-aiostreams" ''
    set -eu
    umask 077
    envFile="${state}/aiostreams.env"
    if [ ! -e "$envFile" ]; then
      tmp=$(${pkgs.coreutils}/bin/mktemp "${state}/.env.XXXXXX")
      trap 'rm -f "$tmp"' EXIT
      {
        printf 'BASE_URL=https://aio.dardery.work\n'
        printf 'SECRET_KEY=%s\n' "$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        printf 'AIOSTREAMS_AUTH=admin:%s\n' "$(${pkgs.openssl}/bin/openssl rand -hex 24)"
        printf 'AIOSTREAMS_AUTH_REQUIRED=true\n'
      } > "$tmp"
      # Publish only a complete file, never overwrite a pre-existing key.
      ln "$tmp" "$envFile"
    fi
    chmod 600 "$envFile"
  '';
  connect = pkgs.writeShellApplication {
    name = "homeserver-connect";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.systemd ];
    text = builtins.readFile ./connect.sh;
  };
  compose = "${pkgs.podman-compose}/bin/podman-compose --project-name aiostreams --file /etc/homeserver/aiostreams/compose.yaml";
in {
  services.adguardhome = {
    enable = true;
    mutableSettings = true;
    settings = null; # first-run wizard; keep web UI on 3000 when configuring it
  };
  networking.firewall.allowedTCPPorts = [ 53 3000 ];
  networking.firewall.allowedUDPPorts = [ 53 ];

  virtualisation.podman.enable = true;
  services.cockpit.plugins = [ pkgs.cockpit-podman ];
  environment.systemPackages = [ pkgs.podman-compose pkgs.openssl pkgs.cloudflared connect ];
  systemd.sockets.podman.wantedBy = [ "sockets.target" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/homeserver 0700 root root -"
    "d ${state} 0700 root root -"
    "d /var/lib/homeserver/cloudflared 0700 root root -"
  ];
  environment.etc."homeserver/aiostreams/compose.yaml".source = ./compose.yaml;
  environment.etc."homeserver/aiostreams/aiostreams.env.example".source = ./aiostreams.env.example;

  systemd.services.aiostreams-stack = {
    description = "AIOStreams Compose stack";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
    restartTriggers = [ ./compose.yaml initAio ];
    path = [ pkgs.podman pkgs.podman-compose ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Remove only the obsolete connector container during migration.
      ExecStartPre = [
        "${initAio}"
        "${pkgs.podman}/bin/podman rm -f --ignore aiostreams-cloudflared"
      ];
      ExecStart = "${compose} up -d";
      ExecStop = "${compose} down";
      TimeoutStartSec = "10min";
      TimeoutStopSec = "2min";
    };
  };
  # Remotely managed Homelab tunnel. The token is never part of a Nix derivation.
  systemd.services.cloudflared = {
    description = "Cloudflare Tunnel (homelab)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
    unitConfig.ConditionFileNotEmpty = "/var/lib/homeserver/cloudflared/token";
    serviceConfig = {
      DynamicUser = true;
      LoadCredential = "homelab-token:/var/lib/homeserver/cloudflared/token";
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token-file %d/homelab-token";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
}
