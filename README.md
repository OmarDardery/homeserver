# Homeserver

Native NixOS 26.05 homeserver: Cockpit, ble.sh, Klipper, Moonraker, Mainsail, AdGuard Home and Podman with Cockpit container management.

## Install

On an existing conventional NixOS installation, authenticate Nix to GitHub first (this repository is private), then run as root:

```sh
sudo nix --extra-experimental-features 'nix-command flakes' run github:OmarDardery/homeserver
```

Keep your GitHub access token in root's protected Nix configuration (`access-tokens = github.com=...`), never in this repository or a shell command. For custom host flakes, import `homeserver.nixosModules.default` instead of running the installer. The installer does not partition disks or replace your existing hardware configuration.

Cockpit: `https://SERVER-IP:9090` (existing system account). Mainsail: `http://SERVER-IP`. Moonraker is proxied by nginx on port 80; its backend listens on loopback. Keep these services on a trusted LAN, not directly on the public internet.

## AdGuard Home DNS

Visit `http://SERVER-IP:3000` and complete the initial setup wizard. Keep the admin interface on port 3000 (port 80 is reserved for Mainsail). Select the server's stable LAN IP for the DNS listener on port 53 to avoid conflicting with a local DNS stub resolver; choose an admin password and upstream resolvers. Then configure the router DHCP DNS option to advertise the server's LAN IP. Do not forward DNS or admin ports from the internet. The existing host DNS configuration is not modified. Settings persist in the AdGuard service's state directory.

## AIOStreams and Cloudflare Tunnel

Both services share one [Compose file](compose.yaml) and one private Podman network. AIOStreams data is persisted in a named volume. Its host port 8080 is loopback-only; the tunnel reaches it directly at `http://aiostreams:3000`. Configure that origin in the Cloudflare Zero Trust dashboard with the public hostname matching BASE_URL (example: aiostreams.dardery.work). Only expose AIOStreams, not Cockpit, Mainsail, or AdGuard.

First-time setup after installation (do not overwrite existing secrets):

```sh
sudo install -m 600 -o root -g root /etc/homeserver/aiostreams/aiostreams.env.example /var/lib/homeserver/aiostreams/aiostreams.env
sudo install -m 600 -o root -g root /etc/homeserver/aiostreams/cloudflared.env.example /var/lib/homeserver/aiostreams/cloudflared.env
openssl rand -hex 32
sudoedit /var/lib/homeserver/aiostreams/aiostreams.env
sudoedit /var/lib/homeserver/aiostreams/cloudflared.env
sudo systemctl start aiostreams-stack
```

Replace SECRET_KEY with the generated key and TUNNEL_TOKEN with your remotely managed tunnel token. Keep the key stable across updates and backups. The stack starts automatically on boot once both environment files exist. Never commit these files, put credentials in Nix expressions, or share container inspection output containing secrets. Set up AIOStreams account authentication in its dashboard before sharing the public URL.

In Cockpit, enable administrative access and open **Podman containers** to inspect logs, restart individual containers, or manage images and volumes. Use **Services → aiostreams-stack** for whole-stack start/stop. Individual container edits in Cockpit are not declarative; edit the repository's Compose file and reinstall to persist changes. To update images:

```sh
sudo podman-compose -p aiostreams -f /etc/homeserver/aiostreams/compose.yaml pull
sudo systemctl restart aiostreams-stack
```

Images use the upstream stable/latest tags, not immutable digests. Back up the named volume and both protected env files before updating. Stopping the stack does not delete its data volume.

## Printer

Optionally pass `-- --printer-config /path/to/config-directory` (or a single printer.cfg) at installation. Supply your verified printer configuration, including the MCU serial path, thermistor types and safety limits. Without it, Klipper intentionally has no usable hardware configuration. The installer refuses to overwrite a non-placeholder printer.cfg. Printer files and uploads are mutable under `/srv/printer_data`.

## Maintenance

Re-run the installation command to refresh the managed module; the host flake pins the initial Nixpkgs revision. Update that revision deliberately in `/etc/nixos/flake.nix` before rebuilding if desired. Rebuild with `sudo nixos-rebuild switch --flake path:/etc/nixos#homeserver`. Use `sudo nixos-rebuild switch --rollback` to roll back an activated generation; printer data is not rolled back. Back up `/etc/nixos` and `/srv/printer_data` separately. Do not run during an active print.

## Checks

CI evaluates a test NixOS host and checks the installer app. Hardware operation requires on-device verification.
