{ pkgs, lib, ... }:
let data = "/srv/printer_data";
in {
  imports = [ ./network-services.nix ./secrets ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  time.timeZone = lib.mkDefault "Africa/Cairo";
  security.polkit.enable = true;
  # Keep the headless server running with the laptop lid closed.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    # Always-on server: idle time and sleep keys never suspend or hibernate.
    IdleAction = "ignore";
    HandleSuspendKey = "ignore";
    HandleSuspendKeyLongPress = "ignore";
    HandleHibernateKey = "ignore";
    HandleHibernateKeyLongPress = "ignore";
  };
  # Refuse every sleep state, including requests from Cockpit, GNOME or systemctl.
  systemd.targets = lib.genAttrs
    [ "sleep" "suspend" "hibernate" "hybrid-sleep" "suspend-then-hibernate" ]
    (_: { enable = false; });
  # Blank the built-in display after 5 idle minutes to save power and the panel.
  boot.kernelParams = [ "consoleblank=300" ];
  # Stable serial alias for the SKR Mini E3 V3.0 running Klipper.
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", KERNEL=="ttyACM*", ATTRS{idVendor}=="1d50", ATTRS{idProduct}=="614e", SYMLINK+="klipper-mcu", GROUP="dialout", MODE="0660"
  '';
  services.cockpit = {
    enable = true;
    port = 9090;
    openFirewall = true;
    # NixOS merges these with its built-in localhost origin.
    allowed-origins = [
      "https://cockpit.dardery.work"
      "https://192.168.1.9:9090"
      "https://192.168.1.240:9090"
      "https://cockpit.home.arpa:9090"
    ];
    settings.WebService.LoginTo = false;
  };
  environment.systemPackages = with pkgs; [ blesh git nano curl htop tmux ];
  programs.bash.interactiveShellInit = ''
    if [[ $- == *i* && -t 0 && -t 1 && $TERM != dumb && -z ''${BLE_VERSION:-} ]]; then
      source "$(${pkgs.blesh}/bin/blesh-share)/ble.sh" --attach=none
      ble-attach
    fi
  '';
  users.groups.klipper = {};
  users.users.klipper = {
    isSystemUser = true;
    group = "klipper";
    extraGroups = [ "dialout" ];
  };
  systemd.tmpfiles.rules = [
    "d ${data} 0750 klipper klipper -"
    "d ${data}/config 0750 klipper klipper -"
    "d ${data}/gcodes 0750 klipper klipper -"
    "d ${data}/logs 0750 klipper klipper -"
    "Z ${data}/config - klipper klipper -"
  ];
  services.klipper = {
    enable = true;
    user = "klipper";
    group = "klipper";
    configDir = "${data}/config";
    configFile = ./printer-placeholder.cfg;
    mutableConfig = true;
    logFile = "${data}/logs/klippy.log";
  };
  systemd.services.klipper.serviceConfig.ReadWritePaths = [ data ];
  services.moonraker = {
    enable = true;
    user = "klipper";
    group = "klipper";
    stateDir = data;
    address = "127.0.0.1";
    port = 7125;
    allowSystemControl = false;
    settings.authorization = {
      trusted_clients = [ "192.168.1.0/24" "127.0.0.1" "::1" ];
      force_logins = true;
    };
  };
  services.mainsail = {
    enable = true;
    hostName = "mainsail";
    nginx = {
      default = true;
      extraConfig = "client_max_body_size 1024M;";
    };
  };
  # Extend the generated vhost, not the Mainsail nginx submodule: its
  # location defaults otherwise conflict with the built-in proxy targets.
  services.nginx.virtualHosts.mainsail.locations = {
    "~ ^/(printer|api|access|machine|server)/".recommendedProxySettings = true;
    "/websocket".recommendedProxySettings = true;
  };
  networking.firewall.allowedTCPPorts = [ 80 ];
  # Private LAN names (resolved by an AdGuard wildcard rewrite *.home.arpa -> this
  # server). Mainsail is the default vhost, so printer.home.arpa only needs an alias.
  services.nginx.virtualHosts = {
    mainsail.serverAliases = [ "printer.home.arpa" ];
    "aio.home.arpa".locations."/" = {
      proxyPass = "http://127.0.0.1:8080";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
    "adguard.home.arpa".locations."/" = {
      proxyPass = "http://127.0.0.1:3000";
      recommendedProxySettings = true;
    };
  };
  # Static LAN address for the wired interface (NetworkManager). The profile has a
  # higher autoconnect priority than the default DHCP "Wired connection".
  networking.networkmanager.ensureProfiles.profiles.homeserver-lan = {
    connection = {
      id = "homeserver-lan";
      type = "ethernet";
      interface-name = "enp8s0";
      autoconnect-priority = 100;
    };
    ipv4 = {
      method = "manual";
      address1 = "192.168.1.240/24,192.168.1.1";
      dns = "192.168.1.1;";
    };
    ipv6.method = "auto";
  };
}
