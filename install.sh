# Run within writeShellApplication.
if [[ ! -e /etc/NIXOS ]]; then
  echo 'Run on an installed NixOS system.' >&2
  exit 1
fi
if (( EUID != 0 )); then
  echo 'Run with sudo nix run.' >&2
  exit 1
fi
printer_source=""
tunnel_token_file=""
while (( $# )); do
  case "$1" in
    --printer-config) printer_source="${2:?Provide a directory or printer.cfg}"; shift 2 ;;
    --tunnel-token-file) tunnel_token_file="${2:?Provide the Homelab tunnel token file}"; shift 2 ;;
    --help) echo 'Usage: homeserver-install [--printer-config DIRECTORY_OR_FILE] [--tunnel-token-file FILE]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ -n "$tunnel_token_file" && ! -s "$tunnel_token_file" ]]; then
  echo 'Tunnel token file does not exist or is empty.' >&2; exit 1
fi
root=/etc/nixos
managed="$root/homeserver"
if [[ ! -f "$root/configuration.nix" ]]; then
  echo 'No /etc/nixos/configuration.nix; import nixosModules.default manually.' >&2; exit 1
fi
if [[ -e "$root/flake.nix" ]] && ! grep -Fqx '  # homeserver-installer-managed' "$root/flake.nix"; then
  echo 'Existing custom flake detected. Import nixosModules.default instead.' >&2; exit 1
fi
if [[ -e "$managed" && ! -f "$managed/.homeserver-managed" ]]; then
  echo "Refusing to overwrite unmanaged $managed" >&2; exit 1
fi
if [[ -n "$printer_source" ]]; then
  if [[ -f "$printer_source" ]]; then
    [[ -r "$printer_source" ]] || exit 1
  elif [[ -d "$printer_source" && -f "$printer_source/printer.cfg" ]]; then
    if [[ -n "$(find "$printer_source" ! -type f ! -type d -print -quit)" ]]; then
      echo 'Printer config directory must contain regular files only.' >&2; exit 1
    fi
  else
    echo 'Printer configuration not found.' >&2; exit 1
  fi
  if [[ -e /srv/printer_data/config/printer.cfg ]] && ! cmp -s /srv/printer_data/config/printer.cfg "$HOMESERVER_SOURCE/printer-placeholder.cfg"; then
    echo 'Existing printer.cfg detected; will not overwrite it.' >&2; exit 1
  fi
fi
install -d -m 0755 "$managed"
touch "$managed/.homeserver-managed"
for file in module.nix network-services.nix compose.yaml aiostreams.env.example; do
  install -m 0644 "$HOMESERVER_SOURCE/$file" "$managed/$file"
done
rm -f "$managed/cloudflared.env.example"
install -m 0644 "$HOMESERVER_SOURCE/printer-placeholder.cfg" "$managed/printer-placeholder.cfg"
if [[ ! -e "$root/flake.nix" ]]; then
  cat > "$root/flake.nix" <<FLAKE
{
  # homeserver-installer-managed
  description = "Existing NixOS host with homeserver services";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/$HOMESERVER_NIXPKGS_REV";
  outputs = { nixpkgs, ... }: {
    nixosConfigurations.homeserver = nixpkgs.lib.nixosSystem {
      system = "$(uname -m)-linux";
      modules = [ ./configuration.nix ./homeserver/module.nix ];
    };
  };
}
FLAKE
fi
nix --extra-experimental-features 'nix-command flakes' build --no-link "path:$root#nixosConfigurations.homeserver.config.system.build.toplevel"
if [[ -n "$printer_source" ]]; then
  install -d -m 0750 /srv/printer_data/config
  if [[ -d "$printer_source" ]]; then
    if cmp -s /srv/printer_data/config/printer.cfg "$HOMESERVER_SOURCE/printer-placeholder.cfg"; then
      rm /srv/printer_data/config/printer.cfg
    fi
    cp -rn "$printer_source/." /srv/printer_data/config/
  else
    install -m 0640 "$printer_source" /srv/printer_data/config/printer.cfg
  fi
fi
if [[ -n "$tunnel_token_file" ]]; then
  install -d -m 0700 /var/lib/homeserver/cloudflared
  if [[ "$tunnel_token_file" != /var/lib/homeserver/cloudflared/token ]]; then
    install -m 0600 -o root -g root "$tunnel_token_file" /var/lib/homeserver/cloudflared/token
  fi
fi
nixos-rebuild switch --flake "path:$root#homeserver"
echo 'Cockpit: https://SERVER-IP:9090 | Mainsail: http://SERVER-IP'
echo 'Printer config: /srv/printer_data/config/printer.cfg'
echo 'AdGuard Home: http://SERVER-IP:3000 | DNS: port 53'
echo 'AIOStreams: configure its private env file; Cloudflared: configure the Homelab token file (see README).' 
