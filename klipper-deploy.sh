#!/usr/bin/env bash
# Deploy klipper/printer.cfg and klipper/macros.cfg to the printer.
# Keeps the printer's own SAVE_CONFIG block (z_offset, meshes, PID),
# backs up the current printer.cfg, and refuses to run mid-print.
# Usage: sudo ./klipper-deploy.sh [CONFIG_DIR]   (default /srv/printer_data/config)
set -euo pipefail

src="$(dirname "$(readlink -f "$0")")/klipper"
dest="${1:-/srv/printer_data/config}"
marker='^#\*# <-* SAVE_CONFIG -*>$'

if (( EUID != 0 )); then
  echo 'Run with sudo.' >&2; exit 1
fi
[[ -f "$src/printer.cfg" && -f "$src/macros.cfg" ]] || { echo "Missing $src/*.cfg" >&2; exit 1; }
[[ -d "$dest" ]] || { echo "No config directory at $dest" >&2; exit 1; }

# Refuse while printing (Moonraker on loopback is a trusted client).
if state="$(curl -fsS --max-time 3 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' 2>/dev/null)"; then
  if grep -Eq '"state": *"(printing|paused)"' <<<"$state"; then
    echo 'A print is active or paused; not deploying.' >&2; exit 1
  fi
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "/$marker/,\$d" "$src/printer.cfg" > "$tmp"
if [[ -f "$dest/printer.cfg" ]] && grep -q "$marker" "$dest/printer.cfg"; then
  sed -n "/$marker/,\$p" "$dest/printer.cfg" >> "$tmp"
  echo 'Kept the printer'"'"'s existing SAVE_CONFIG block.'
else
  sed -n "/$marker/,\$p" "$src/printer.cfg" >> "$tmp"
  echo 'No SAVE_CONFIG block on the printer; using the repository one.'
fi

if [[ -f "$dest/printer.cfg" ]]; then
  backup="$dest/printer.cfg.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$dest/printer.cfg" "$backup"
  echo "Backup: $backup"
fi
install -m 0640 -o klipper -g klipper "$tmp" "$dest/printer.cfg"
install -m 0640 -o klipper -g klipper "$src/macros.cfg" "$dest/macros.cfg"
echo 'Deployed. Apply with: sudo systemctl restart klipper'
