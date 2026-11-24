{ pkgs, ... }:
let
  state = "/var/lib/homeserver/aiostreams";
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
  environment.systemPackages = [ pkgs.podman-compose pkgs.openssl ];
  systemd.sockets.podman.wantedBy = [ "sockets.target" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/homeserver 0700 root root -"
    "d ${state} 0700 root root -"
  ];
  environment.etc."homeserver/aiostreams/compose.yaml".source = ./compose.yaml;
  environment.etc."homeserver/aiostreams/aiostreams.env.example".source = ./aiostreams.env.example;
  environment.etc."homeserver/aiostreams/cloudflared.env.example".source = ./cloudflared.env.example;

  systemd.services.aiostreams-stack = {
    description = "AIOStreams and Cloudflare Tunnel Compose stack";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
    unitConfig.ConditionPathExists = [
      "${state}/aiostreams.env"
      "${state}/cloudflared.env"
    ];
    restartTriggers = [ ./compose.yaml ];
    path = [ pkgs.podman pkgs.podman-compose ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${compose} up -d";
      ExecStop = "${compose} down";
      TimeoutStartSec = "10min";
      TimeoutStopSec = "2min";
    };
  };
}
