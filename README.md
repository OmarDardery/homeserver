# Homeserver

Native NixOS 26.05 homeserver: Cockpit, ble.sh, Klipper, Moonraker, Mainsail, AdGuard Home and Podman with Cockpit container management.

## Install

On an existing conventional NixOS installation, authenticate Nix to GitHub first (this repository is private), then run as root:

```sh
sudo nix --extra-experimental-features 'nix-command flakes' run github:OmarDardery/homeserver
```

Keep your GitHub access token in root's protected Nix configuration (`access-tokens = github.com=...`), never in this repository or a shell command. For custom host flakes, import `homeserver.nixosModules.default` instead of running the installer. The installer does not partition disks or replace your existing hardware configuration. No Cloudflare token is needed or requested during installation. All local services are installed first; the tunnel stays inactive unless previously connected.

The same command also deploys the printer configuration from [klipper/](klipper) and restarts Klipper (see Printer below).

Cockpit: `https://192.168.1.9:9090` or `https://192.168.1.240:9090` (existing system account); both exact origins are allowed. The server keeps its DHCP address and also gets 192.168.1.240 on its default-route interface via `homeserver-lan-address.service` (keep 192.168.1.240 outside your router's DHCP pool to avoid a conflict). If the address changes, add the exact HTTPS origin including port 9090 to `services.cockpit.allowed-origins` in the host configuration and rebuild. Do not allow wildcard origins. Mainsail: `http://192.168.1.240`. Moonraker is proxied by nginx on port 80; its backend listens on loopback. Keep these services on a trusted LAN, not directly on the public internet.

## AdGuard Home DNS

Visit `http://192.168.1.240:3000` and complete the initial setup wizard. Keep the admin interface on port 3000 (port 80 is reserved for Mainsail). Select the server's stable LAN IP for the DNS listener on port 53 to avoid conflicting with a local DNS stub resolver; choose an admin password and upstream resolvers. Then configure the router DHCP DNS option to advertise the server's LAN IP. Do not forward DNS or admin ports from the internet. The existing host DNS configuration is not modified. Settings persist in the AdGuard service's state directory.

## AIOStreams (Podman)

The [Compose file](compose.yaml) manages only AIOStreams. Persistent data uses the existing named volume and the host port 8080 is loopback-only.

On first start the encrypted secret manager generates the encryption key and a random admin password. Existing credentials are migrated and preserved. Open **Cockpit → Tools → Secrets** with administrative access to reveal or edit credentials.

Local preview without Cloudflare: if SSH is enabled on the host, forward port 8080 using `ssh -L 8080:127.0.0.1:8080 USER@192.168.1.240`, then open `http://localhost:8080`. The canonical addon URL is `https://aio.dardery.work`; remote clients require the tunnel to be connected.

In Cockpit, use **Podman containers** for container logs and **Services → aiostreams-stack** for whole-stack start/stop. To update the image:

```sh
sudo podman-compose -p aiostreams -f /etc/homeserver/aiostreams/compose.yaml pull
sudo systemctl restart aiostreams-stack
```

The image uses the upstream latest tag, not an immutable digest. Back up the named volume and encrypted secret store and its age key before updating. Stopping the stack does not delete its data.

## Cloudflare Tunnel (native systemd service)

The existing remotely managed `homelab` tunnel is the sole connector. Cloudflared runs directly on NixOS as `cloudflared.service`, not in Podman. Cloudflare holds the ingress configuration:

| Public hostname | Local origin | Access |
|---|---|---|
| 3dprinter.dardery.work | http://127.0.0.1:80 | Cloudflare Access (owner only) |
| aio.dardery.work | http://127.0.0.1:8080 | Application authentication |
| cockpit.dardery.work | https://127.0.0.1:9090 | Cloudflare Access (owner only) |

Unmatched routes return 404. AdGuard remains LAN-only. Cockpit uses its local self-signed certificate; verification is disabled only for that loopback origin, and browser traffic remains HTTPS. The printer and Cockpit routes require valid Access JWTs at the connector.

No tunnel token is required for installation. When ready, open **Cockpit → Tools → Secrets**, set `CLOUDFLARE_TUNNEL_TOKEN` to the Homelab connector token, and Save and apply. Alternatively run `sudo homeserver-connect` in a private terminal. Verify tunnel health in Cloudflare.

Routing is deliberately remotely managed: the dashboard or API changes exact hostnames without a NixOS rebuild. [cloudflare/ingress.json](cloudflare/ingress.json) records the intended routes; it is a reference snapshot, not an automatically applied local configuration. Do not use a wildcard forwarding rule: the explicit routes preserve independent Access enforcement. A local reverse proxy would add another routing layer without benefit for these three services.

Migration: the old AIOStreams Cloudflared container is removed when the stack starts. Delete any obsolete `/var/lib/homeserver/aiostreams/cloudflared.env` after verifying the new tunnel. Do not delete the AIOStreams data volume.

## Printer

`nix run` deploys the HyperCube 300 V2 configuration in [klipper/](klipper) (SKR Mini E3 V3, M12 probe, sensorless X/Y: `printer.cfg` and `macros.cfg`) after the system switch, then restarts Klipper. The printer's own SAVE_CONFIG block (z_offset, meshes, PID) is kept, the previous printer.cfg is backed up next to it, and nothing is changed while a print is active or paused. Pass `-- --printer-config /path/to/dir-or-printer.cfg` to deploy a different configuration, or `-- --no-printer-config` to leave the printer untouched. Printer files and uploads are mutable under `/srv/printer_data`.

To update only the printer configuration:

```sh
sudo nix --extra-experimental-features 'nix-command flakes' run github:OmarDardery/homeserver#klipper-deploy -- --restart
```

From a checkout, `sudo ./klipper-deploy.sh --restart` does the same.

Deploys keep the printer's SAVE_CONFIG block, back up replaced files to `deploy-backups/` in the config directory (five kept), and, if Klipper reports a configuration error after the restart, restore the previous files automatically. A board communication error (for example a firmware protocol mismatch after a Klipper update) is reported, not rolled back; reflash the SKR in that case.

The purge primes the nozzle, draws two solid 0.8 mm × 0.4 mm lines just in front of the printed objects (inside the adaptive mesh; front edge if objects are not labelled) and wipes without retracting, so the first layer starts with a full nozzle. Macros: `LOAD_FILAMENT` / `UNLOAD_FILAMENT` (`TEMP=`, `BOWDEN=` tube length, default 450 mm: measure yours), `M600` filament change (pause and park), firmware retraction (`G10`/`G11`, tune live with `SET_RETRACTION`), optional heat soak (`START_PRINT ... SOAK=10`), and skew correction that loads automatically once a `default` profile is saved. Input shaper sections are ready to uncomment once an ADXL345 is wired. To stop the frame shaking, motion limits are gentler (acceleration 1500, corner speed 4); `SMOOTH_MODE` lowers them further at runtime (also `START_PRINT ... SMOOTH=1`), `NORMAL_MODE` restores them.

Set the OrcaSlicer start G-code to `START_PRINT BED_TEMP=[bed_temperature_initial_layer_single] EXTRUDER_TEMP=[nozzle_temperature_initial_layer]` and the end G-code to `END_PRINT`, and enable "Exclude objects" so START_PRINT probes an adaptive mesh over the printed area only. Still to tune after deploying: pressure advance, bed PID (`PID_CALIBRATE HEATER=heater_bed TARGET=65`, then `SAVE_CONFIG`), and the bed screw positions for `SCREWS_TILT_CALCULATE`.

## OrcaSlicer profile

[orca/](orca) holds the HyperCube profiles: printer `HyperCube 300 V2 0.4 Volcano` (Klipper flavour, 300 × 300 × 300, START_PRINT/END_PRINT/M600 wired up, object labels on, Bowden retraction 4 mm), process `0.20mm Standard @HyperCube` and filament `Patron PETG HS @HyperCube` (245/240 °C, bed 70/65 °C). In OrcaSlicer use **File → Import → Import Configs…** and select the three JSON files. If import is refused, copy them into `~/.config/OrcaSlicer/user/default/machine`, `process` and `filament` respectively and restart OrcaSlicer.

They were tested by slicing with OrcaSlicer 2.5.2 and running the resulting G-code through Klipper in batch mode against this configuration. Smooth mode is a ceiling: OrcaSlicer's per-feature acceleration commands are clamped to it while `SMOOTH_MODE` is active.


Re-run the installation command to refresh the managed module; the host flake pins the initial Nixpkgs revision. Update that revision deliberately in `/etc/nixos/flake.nix` before rebuilding if desired. Rebuild with `sudo nixos-rebuild switch --flake path:/etc/nixos#homeserver`. Use `sudo nixos-rebuild switch --rollback` to roll back an activated generation; printer data is not rolled back. Back up `/etc/nixos` and `/srv/printer_data` separately. Do not run during an active print.


### Updating from Cockpit

**Cockpit → Tools → Secrets → Server update** shows the deployed commit, the latest commit on GitHub and the changes in between. **Update server** runs `homeserver-update.service`, which:

1. refuses while a print is active or paused;
2. publishes this server's encrypted secrets to GitHub if the file is missing there, and stops if GitHub holds different ones (use **Pull** or **Push** first);
3. runs `nix run --refresh github:OmarDardery/homeserver`: rebuilds NixOS, deploys the printer config and restarts Klipper (rolling the printer config back if Klipper rejects it);
4. checks that Klipper, Moonraker, nginx and Cockpit are running, and fails visibly if not.

The repository is private, so the update reuses the fine-grained token saved under GitHub sync for this fetch (Contents: read and write also covers the download); without it, root's `access-tokens` in nix.conf is used. The service is never restarted by the switch it triggers, and the Cockpit page resumes the log after Cockpit reconnects. **Push to GitHub** replaces the encrypted file on GitHub with this server's ciphertext; values and the age key never leave the server. The button exists after one manual install of this version.

## Checks

CI evaluates a test NixOS host and checks the installer app. Hardware operation requires on-device verification.

## Secrets (SOPS + age + sops-nix)

The native Cockpit Secrets plugin uses Cockpit's privileged bridge and a root-only helper, not a separate server. Values are encrypted in `/var/lib/homeserver/secrets/runtime.enc`; the machine age identity is `/var/lib/homeserver/secrets/age.key`. sops-nix installs the encrypted document under `/run/secrets`; service-specific credentials are rendered under `/run/homeserver-secrets` (root only). Do not commit either the age identity or plaintext. Back up the encrypted document and identity securely and separately. Host root, privileged Cockpit users, and rootful Podman administrators can access plaintext; this is not protection from a compromised root account.

Set, reveal, copy, edit or delete variables in Cockpit. The page shows each variable's service, a GitHub sync badge and recent encrypted commits (commit messages name changed variables, never values). **Generate** creates valid random values for `SECRET_KEY` and `AIOSTREAMS_AUTH`. **Import .env** saves several variables in one commit and one restart. **Download encrypted backup** saves the ciphertext `runtime.enc`; it is useless without the separately backed-up age key. Copied values are cleared from the clipboard after 15 seconds where the browser allows it. New variables are scoped to AIOStreams except the Cloudflare token. Required AIOStreams variables cannot be removed, and authentication cannot be disabled. Values are restricted to literal dotenv-safe characters; complex values need a future escaping implementation. Changing SECRET_KEY can invalidate encrypted addon settings. Use a local Cockpit session when changing the tunnel token. Reveal values expire after 15 seconds. Saving applies only the affected service; Retry apply restarts both. If apply fails, the desired encrypted value is retained and can be retried. AIOStreams recreates its container without deleting the persistent volume.

During initial upgrade, existing plain env/token files are imported and removed after encrypted decryption and runtime materialization. Back up before upgrading; a legacy file with unsupported formatting fails closed. If reverting to a pre-secrets generation, restore protected legacy files from backup before starting services. No remote secrets provider is required. No automatic cloud key provisioning occurs.

## GitOps secrets synchronization

The repository's `main:secrets/runtime.enc` is the canonical **encrypted** environment document after connecting GitHub. The local copy is a boot cache read by sops-nix, so rebooting does not need internet access. No secrets are sent by the CI workflow. Only the encrypted document is committed; the machine age identity and GitHub write token stay in root-only files under `/var/lib/homeserver/secrets`, outside the Nix store and Git. Container administrators can still inspect the runtime environment.

1. Install normally (no Cloudflare or GitHub write token needed). Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) scoped only to this repository with **Contents: Read and write**. This is separate from the read credential used by Nix to fetch the private repository.
2. In Cockpit → Tools → Secrets, paste it in **Connect / rotate token**. If the encrypted document is absent, the current encrypted local values are published. If it already exists and differs, it is not overwritten.
3. Save an environment variable. The server encrypts the complete document and commits only that file using GitHub's optimistic blob-SHA check, then installs the local ciphertext and applies the changes. Network or conflict failures stop the edit before local application. A lost response after a remote commit can be reconciled via Pull. If applying fails after a commit, Retry apply is available.
4. **Pull encrypted secrets from GitHub** explicitly validates and decrypts the remote document before replacing the cache and restarting affected services. No automatic overwriting of local state or forced Git pushes. Until GitHub is connected, changes are local only. If main is branch-protected against direct file updates, writes will fail rather than bypass the protection.

### Reinstall / recover

Back up `/var/lib/homeserver/secrets/age.key` separately in a secure password manager or offline encrypted backup. Never commit it. GitHub cannot recover this key for you. Use a private location outside `/etc/nixos` and any Git checkout.

On a new host, after authenticating Nix to the private repo, run:

```sh
sudo nix --extra-experimental-features 'nix-command flakes' run --refresh github:OmarDardery/homeserver -- --age-key-file /root/recovery/age.key
```

The installer restores the repository ciphertext if present and verifies that the provided identity can decrypt it. It never overwrites an existing local secret document or identity. Without the correct age key a fresh restore stops rather than generating replacement credentials. Reconnect GitHub write access from Cockpit after recovery. This restores environment variables, not printer files, AdGuard settings or Podman volume data; back those up separately. The mutable secret cache is not automatically rolled back with NixOS generations.

GitHub changes to the NixOS modules are still deployed with the same installer. Host-specific hardware, existing users and boot configuration remain local. There is intentionally no automatic unattended OS activation.
