#!/usr/bin/env bash
# Deploy a Klipper configuration to /srv/printer_data/config.
# Source: a directory with printer.cfg (plus any other *.cfg, e.g. macros.cfg)
# or a single printer.cfg. Defaults to this repository's klipper/ directory.
# Keeps the printer's own SAVE_CONFIG block (z_offset, meshes, PID), backs up
# the current printer.cfg, and refuses to run while a print is active (exit 3).
# Usage: homeserver-klipper-deploy [--source DIR_OR_FILE] [--dest DIR] [--restart]
set -euo pipefail

src="${HOMESERVER_SOURCE:-$(dirname "$(readlink -f "$0")")}/klipper"
dest=/srv/printer_data/config
restart=0
while (( $# )); do
  case "$1" in
    --source) src="${2:?Provide a directory or printer.cfg}"; shift 2 ;;
    --dest) dest="${2:?Provide the Klipper config directory}"; shift 2 ;;
    --restart) restart=1; shift ;;
    --help) echo 'Usage: homeserver-klipper-deploy [--source DIR_OR_FILE] [--dest DIR] [--restart]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if (( EUID != 0 )); then
  echo 'Run with sudo.' >&2; exit 1
fi

extras=()
if [[ -f "$src" ]]; then
  main="$src"
elif [[ -d "$src" && -f "$src/printer.cfg" ]]; then
  main="$src/printer.cfg"
  while IFS= read -r -d '' file; do
    extras+=("$file")
  done < <(find "$src" -maxdepth 1 -type f -name '*.cfg' ! -name printer.cfg -print0)
else
  echo "Printer configuration not found: $src" >&2; exit 1
fi

# Refuse while printing (Moonraker on loopback is a trusted client).
if state="$(curl -fsS --max-time 3 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' 2>/dev/null)"; then
  if grep -Eq '"state": *"(printing|paused)"' <<<"$state"; then
    echo 'A print is active or paused; printer config not deployed.' >&2; exit 3
  fi
fi

marker='^#\*# <-* SAVE_CONFIG -*>$'
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "/$marker/,\$d" "$main" > "$tmp"
if [[ -f "$dest/printer.cfg" ]] && grep -q "$marker" "$dest/printer.cfg"; then
  sed -n "/$marker/,\$p" "$dest/printer.cfg" >> "$tmp"
  echo "Kept the printer's existing SAVE_CONFIG block."
else
  sed -n "/$marker/,\$p" "$main" >> "$tmp"
fi

install -d -m 0750 -o klipper -g klipper "$dest"
if [[ -f "$dest/printer.cfg" ]] && ! cmp -s "$tmp" "$dest/printer.cfg"; then
  backup="$dest/printer.cfg.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$dest/printer.cfg" "$backup"
  echo "Backup: $backup"
fi
install -m 0640 -o klipper -g klipper "$tmp" "$dest/printer.cfg"
for file in "${extras[@]}"; do
  install -m 0640 -o klipper -g klipper "$file" "$dest/$(basename "$file")"
done
echo "Klipper config deployed to $dest"

if (( restart )); then
  systemctl restart klipper
  echo 'Klipper restarted.'
else
  echo 'Apply with: sudo systemctl restart klipper'
fi
