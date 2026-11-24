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

## AIOStreams (Podman)

The [Compose file](compose.yaml) manages only AIOStreams. Persistent data uses the existing named volume and the host port 8080 is loopback-only.

First-time setup after installation (do not overwrite an existing secret):

```sh
sudo install -m 600 -o root -g root /etc/homeserver/aiostreams/aiostreams.env.example /var/lib/homeserver/aiostreams/aiostreams.env
openssl rand -hex 32
sudoedit /var/lib/homeserver/aiostreams/aiostreams.env
sudo systemctl start aiostreams-stack
```

Replace SECRET_KEY with the generated key, and retain that key across updates. Set BASE_URL=https://aio.dardery.work (also update any existing env file with an older hostname). Enable appropriate AIOStreams application authentication before sharing the URL; Stremio clients may not support a Cloudflare Access login.

In Cockpit, use **Podman containers** for container logs and **Services → aiostreams-stack** for whole-stack start/stop. To update the image:

```sh
sudo podman-compose -p aiostreams -f /etc/homeserver/aiostreams/compose.yaml pull
sudo systemctl restart aiostreams-stack
```

The image uses the upstream latest tag, not an immutable digest. Back up the named volume and protected env file before updating. Stopping the stack does not delete its data.

## Cloudflare Tunnel (native systemd service)

The existing remotely managed `homelab` tunnel is the sole connector. Cloudflared runs directly on NixOS as `cloudflared.service`, not in Podman. Cloudflare holds the ingress configuration:

| Public hostname | Local origin | Access |
|---|---|---|
| 3dprinter.dardery.work | http://127.0.0.1:80 | Cloudflare Access (owner only) |
| aio.dardery.work | http://127.0.0.1:8080 | Application authentication |
| cockpit.dardery.work | https://127.0.0.1:9090 | Cloudflare Access (owner only) |

Unmatched routes return 404. AdGuard remains LAN-only. Cockpit uses its local self-signed certificate; verification is disabled only for that loopback origin, and browser traffic remains HTTPS. The printer and Cockpit routes require valid Access JWTs at the connector.

Retrieve the **homelab** connector token (not the deleted aiostreams tunnel token) from the Cloudflare Zero Trust dashboard. Save it as a single-line root-only file, without a TUNNEL_TOKEN= prefix:

```sh
sudo install -d -m 700 /var/lib/homeserver/cloudflared
sudo install -m 600 /dev/null /var/lib/homeserver/cloudflared/token
sudoedit /var/lib/homeserver/cloudflared/token
sudo systemctl start cloudflared
sudo systemctl status cloudflared
```

Run the file creation command only for a new installation; it truncates an existing token file. Alternatively pass `-- --tunnel-token-file /root/homelab-token` to the installer. The token is loaded using systemd credentials, outside Git and the Nix store. The service starts automatically at boot when its token file exists. If rotating the token, replace the file and restart the service.

Migration: the old AIOStreams Cloudflared container is removed when the stack starts. The old tunnel token is invalid; after confirming the new connector works, delete the obsolete `/var/lib/homeserver/aiostreams/cloudflared.env` file. Do not delete the AIOStreams data volume.

## Printer

Optionally pass `-- --printer-config /path/to/config-directory` (or a single printer.cfg) at installation. Supply your verified printer configuration, including the MCU serial path, thermistor types and safety limits. Without it, Klipper intentionally has no usable hardware configuration. The installer refuses to overwrite a non-placeholder printer.cfg. Printer files and uploads are mutable under `/srv/printer_data`.

## Maintenance

Re-run the installation command to refresh the managed module; the host flake pins the initial Nixpkgs revision. Update that revision deliberately in `/etc/nixos/flake.nix` before rebuilding if desired. Rebuild with `sudo nixos-rebuild switch --flake path:/etc/nixos#homeserver`. Use `sudo nixos-rebuild switch --rollback` to roll back an activated generation; printer data is not rolled back. Back up `/etc/nixos` and `/srv/printer_data` separately. Do not run during an active print.

## Checks

CI evaluates a test NixOS host and checks the installer app. Hardware operation requires on-device verification.
