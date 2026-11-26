{ config, pkgs, ... }:
let
  helper = pkgs.writeShellApplication {
    name = "homeserver-secrets";
    runtimeInputs = [ pkgs.python3 pkgs.sops pkgs.age pkgs.systemd ];
    text = ''
      export HOMESERVER_SOPS_INSTALLER=${config.sops.package}/bin/sops-install-secrets
      export HOMESERVER_SOPS_MANIFEST=${config.system.build.sops-nix-manifest}
      exec ${pkgs.python3}/bin/python3 ${./backend.py} "$@"
    '';
  };
  updater = pkgs.writeShellApplication {
    name = "homeserver-update";
    runtimeInputs = [ helper pkgs.curl pkgs.gnugrep pkgs.jq pkgs.systemd config.nix.package ];
    text = builtins.readFile ./update.sh;
  };
  plugin = pkgs.runCommand "cockpit-homeserver-secrets" {} ''
    mkdir -p "$out/share/cockpit/homeserver-secrets"
    cp ${./cockpit}/* "$out/share/cockpit/homeserver-secrets/"
  '';
in {
  environment.systemPackages = [ helper updater pkgs.sops pkgs.age ];
  services.cockpit.plugins = [ plugin ];
  sops = {
    age.keyFile = "/var/lib/homeserver/secrets/age.key";
    age.sshKeyPaths = [];
    gnupg.sshKeyPaths = [];
    validateSopsFiles = false;
    useSystemdActivation = true;
    secrets.homeserver-runtime = {
      sopsFile = "/var/lib/homeserver/secrets/runtime.enc";
      format = "binary";
      mode = "0400";
    };
  };
  systemd.services.homeserver-secrets-init = {
    description = "Initialize encrypted homeserver secrets";
    unitConfig.DefaultDependencies = false;
    unitConfig.RequiresMountsFor = [ "/var/lib/homeserver" ];
    after = [ "local-fs.target" ];
    before = [ "sops-install-secrets.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${helper}/bin/homeserver-secrets init";
    };
  };
  systemd.services.sops-install-secrets = {
    requires = [ "homeserver-secrets-init.service" ];
    after = [ "homeserver-secrets-init.service" ];
  };
  # Started from Cockpit. It survives the switch it triggers: never restarted
  # or stopped by switch-to-configuration (same approach as system.autoUpgrade).
  systemd.services.homeserver-update = {
    description = "Update the homeserver from GitHub";
    restartIfChanged = false;
    unitConfig.X-StopOnRemoval = false;
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ "/run/current-system/sw" ];
    environment.HOME = "/root";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${updater}/bin/homeserver-update";
    };
  };
  systemd.services.homeserver-secrets-materialize = {
    description = "Prepare runtime-only homeserver credentials";
    requires = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${helper}/bin/homeserver-secrets materialize";
    };
  };
}
