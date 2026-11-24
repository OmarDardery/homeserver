# Homeserver

Native NixOS 26.05 homeserver: Cockpit, ble.sh, Klipper, Moonraker and Mainsail.

## Install

On an existing conventional NixOS installation, authenticate Nix to GitHub first (this repository is private), then run as root:

```sh
sudo nix --extra-experimental-features 'nix-command flakes' run github:OmarDardery/homeserver
```

Keep your GitHub access token in root's protected Nix configuration (`access-tokens = github.com=...`), never in this repository or a shell command. For custom host flakes, import `homeserver.nixosModules.default` instead of running the installer. The installer does not partition disks or replace your existing hardware configuration.

Cockpit: `https://SERVER-IP:9090` (existing system account). Mainsail: `http://SERVER-IP`. Moonraker is proxied by nginx on port 80; its backend listens on loopback. Keep these services on a trusted LAN, not directly on the public internet.

## Printer

Optionally pass `-- --printer-config /path/to/config-directory` (or a single printer.cfg) at installation. Supply your verified printer configuration, including the MCU serial path, thermistor types and safety limits. Without it, Klipper intentionally has no usable hardware configuration. The installer refuses to overwrite a non-placeholder printer.cfg. Printer files and uploads are mutable under `/srv/printer_data`.

## Maintenance

Re-run the installation command to refresh the managed module; the host flake pins the initial Nixpkgs revision. Update that revision deliberately in `/etc/nixos/flake.nix` before rebuilding if desired. Rebuild with `sudo nixos-rebuild switch --flake path:/etc/nixos#homeserver`. Use `sudo nixos-rebuild switch --rollback` to roll back an activated generation; printer data is not rolled back. Back up `/etc/nixos` and `/srv/printer_data` separately. Do not run during an active print.

## Checks

CI evaluates a test NixOS host and checks the installer app. Hardware operation requires on-device verification.
