# Run within writeShellApplication.
if [[ ! -e /etc/NIXOS ]]; then
  echo 'Run on an installed NixOS system.' >&2
  exit 1
fi
if (( EUID != 0 )); then
  echo 'Run with sudo nix run.' >&2
  exit 1
fi
printer_source="$HOMESERVER_SOURCE/klipper"
age_key_source=""
while (( $# )); do
  case "$1" in
    --printer-config) printer_source="${2:?Provide a directory or printer.cfg}"; shift 2 ;;
    --no-printer-config) printer_source=""; shift ;;
    --age-key-file) age_key_source="${2:?Provide the backed-up age identity file}"; shift 2 ;;
    --help) echo 'Usage: homeserver-install [--printer-config DIRECTORY_OR_FILE | --no-printer-config] [--age-key-file FILE]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
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
fi
# Recover a published SOPS document without exposing the key to Nix.
secret_state=/var/lib/homeserver/secrets
remote_cipher="$HOMESERVER_SOURCE/secrets/runtime.enc"
if [[ -n "$age_key_source" ]]; then
  [[ -f "$age_key_source" && -s "$age_key_source" ]] || { echo 'Age identity file missing or empty.' >&2; exit 1; }
  age-keygen -y "$age_key_source" >/dev/null
  if [[ -e "$secret_state/age.key" ]] && ! cmp -s "$age_key_source" "$secret_state/age.key"; then
    echo 'Refusing to replace the existing age identity.' >&2; exit 1
  fi
fi
if [[ -f "$remote_cipher" && ! -e "$secret_state/runtime.enc" ]]; then
  candidate="$secret_state/age.key"
  if [[ -n "$age_key_source" ]]; then candidate="$age_key_source"; fi
  if [[ ! -s "$candidate" ]]; then
    echo 'GitHub contains encrypted secrets. Restore the age identity with --age-key-file before installing.' >&2; exit 1
  fi
  if ! SOPS_AGE_KEY_FILE="$candidate" sops --decrypt --input-type binary --output-type binary "$remote_cipher" >/dev/null 2>&1; then
    echo 'The supplied age identity cannot decrypt the GitHub secrets.' >&2; exit 1
  fi
elif [[ -e "$secret_state/runtime.enc" && ! -s "$secret_state/age.key" && -z "$age_key_source" ]]; then
  echo 'Existing encrypted secrets require the original age identity.' >&2; exit 1
fi
install -d -m 0755 "$managed"
touch "$managed/.homeserver-managed"
for file in module.nix network-services.nix compose.yaml aiostreams.env.example connect.sh; do
  install -m 0644 "$HOMESERVER_SOURCE/$file" "$managed/$file"
done
install -d -m 0755 "$managed/secrets/cockpit"
for file in default.nix backend.py; do
  install -m 0644 "$HOMESERVER_SOURCE/secrets/$file" "$managed/secrets/$file"
done
for file in manifest.json index.html index.js style.css; do
  install -m 0644 "$HOMESERVER_SOURCE/secrets/cockpit/$file" "$managed/secrets/cockpit/$file"
done
rm -f "$managed/cloudflared.env.example"
install -m 0644 "$HOMESERVER_SOURCE/printer-placeholder.cfg" "$managed/printer-placeholder.cfg"
if [[ ! -e "$root/flake.nix" ]]; then
  cat > "$root/flake.nix" <<FLAKE
{
  # homeserver-installer-managed
  description = "Existing NixOS host with homeserver services";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/$HOMESERVER_NIXPKGS_REV";
  inputs.sops-nix = {
    url = "github:Mic92/sops-nix/$HOMESERVER_SOPS_REV";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { nixpkgs, sops-nix, ... }: {
    nixosConfigurations.homeserver = nixpkgs.lib.nixosSystem {
      system = "$(uname -m)-linux";
      modules = [ ./configuration.nix sops-nix.nixosModules.sops ./homeserver/module.nix ];
    };
  };
}
FLAKE
else
  # Upgrade older installer-generated flakes while preserving their Nixpkgs pin.
  if ! grep -q "inputs.sops-nix" "$root/flake.nix"; then
    tmp=$(mktemp "$root/.flake.XXXXXX")
    sed -e '/^  outputs =/i\  inputs.sops-nix = { url = "github:Mic92/sops-nix/'"$HOMESERVER_SOPS_REV"'"; inputs.nixpkgs.follows = "nixpkgs"; };' \
      -e 's/outputs = { nixpkgs, ... }:/outputs = { nixpkgs, sops-nix, ... }:/' \
      -e 's@modules = \[ ./configuration.nix ./homeserver/module.nix \];@modules = [ ./configuration.nix sops-nix.nixosModules.sops ./homeserver/module.nix ];@' "$root/flake.nix" > "$tmp"
    cp -n "$root/flake.nix" "$root/flake.nix.pre-secrets"
    chmod 0644 "$tmp"
    mv "$tmp" "$root/flake.nix"
  fi
fi
nix --extra-experimental-features 'nix-command flakes' build --no-link "path:$root#nixosConfigurations.homeserver.config.system.build.toplevel"
if [[ -n "$age_key_source" || -f "$remote_cipher" ]]; then
  install -d -m 0700 "$secret_state"
  if [[ -n "$age_key_source" && ! -e "$secret_state/age.key" ]]; then
    install -m 0600 -o root -g root "$age_key_source" "$secret_state/age.key"
  fi
  if [[ -f "$remote_cipher" && ! -e "$secret_state/runtime.enc" ]]; then
    install -m 0600 -o root -g root "$remote_cipher" "$secret_state/runtime.enc"
  elif [[ -f "$remote_cipher" ]] && ! cmp -s "$remote_cipher" "$secret_state/runtime.enc"; then
    echo 'GitHub secrets differ from the local cache; use Cockpit Pull to reconcile. Local secrets preserved.' >&2
  fi
fi
nixos-rebuild switch --flake "path:$root#homeserver"
if [[ -n "$printer_source" ]]; then
  deploy_status=0
  homeserver-klipper-deploy --source "$printer_source" --restart || deploy_status=$?
  if (( deploy_status == 3 )); then
    echo 'Printer busy: config not updated. Re-run after the print, or: sudo nix run github:OmarDardery/homeserver#klipper-deploy -- --restart' >&2
  elif (( deploy_status != 0 )); then
    exit "$deploy_status"
  fi
fi
echo 'Cockpit: https://192.168.1.240:9090 | Mainsail: http://192.168.1.240'
echo 'Printer config: /srv/printer_data/config/printer.cfg'
echo 'AdGuard Home: http://192.168.1.240:3000 | DNS: port 53'
echo 'AIOStreams: initialized automatically; credentials in Cockpit → Secrets'
echo 'GitHub secrets: optional; connect GitHub in Cockpit → Secrets.'
echo 'Cloudflare: optional; add CLOUDFLARE_TUNNEL_TOKEN in Cockpit → Secrets.'
