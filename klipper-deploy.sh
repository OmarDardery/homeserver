#!/usr/bin/env bash
# Deploy a Klipper configuration to /srv/printer_data/config.
# Source: a directory with printer.cfg (plus any other *.cfg, e.g. macros.cfg)
# or a single printer.cfg. Defaults to this repository's klipper/ directory.
#
# - Keeps the printer's own SAVE_CONFIG block (z_offset, meshes, PID).
# - Backs up every file it replaces to deploy-backups/<time>/ (keeps 5).
# - Refuses to run while a print is active or paused (exit 3).
# - With --restart: restarts Klipper and, if it reports a configuration
#   error, restores the backup and restarts again (exit 4).
# Usage: homeserver-klipper-deploy [--source DIR_OR_FILE] [--dest DIR] [--restart]
set -euo pipefail

src="${HOMESERVER_SOURCE:-$(dirname "$(readlink -f "$0")")}/klipper"
dest=/srv/printer_data/config
restart=0
moonraker=http://127.0.0.1:7125
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

# Klipper state as "state<TAB>message", empty if Moonraker is unreachable.
klipper_state() {
  curl -fsS --max-time 3 "$moonraker/printer/info" 2>/dev/null \
    | jq -r '.result | "\(.state)\t\(.state_message // "")"' 2>/dev/null || true
}

# Wait for Klipper after a restart. 0 = ready, 1 = error (message on stdout),
# 2 = no verdict (Moonraker down, or still starting, e.g. printer powered off).
wait_klipper() {
  local info state
  sleep 3
  for _ in $(seq 1 30); do
    info="$(klipper_state)"
    state="${info%%$'\t'*}"
    case "$state" in
      ready) return 0 ;;
      error|shutdown) printf '%s\n' "${info#*$'\t'}"; return 1 ;;
    esac
    sleep 1
  done
  return 2
}

# Refuse while printing (Moonraker on loopback is a trusted client).
if state="$(curl -fsS --max-time 3 "$moonraker/printer/objects/query?print_stats=state" 2>/dev/null)"; then
  if grep -Eq '"state": *"(printing|paused)"' <<<"$state"; then
    echo 'A print is active or paused; printer config not deployed.' >&2; exit 3
  fi
fi

marker='^#\*# <-* SAVE_CONFIG -*>$'
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
sed "/$marker/,\$d" "$main" > "$staging/printer.cfg"
if [[ -f "$dest/printer.cfg" ]] && grep -q "$marker" "$dest/printer.cfg"; then
  sed -n "/$marker/,\$p" "$dest/printer.cfg" >> "$staging/printer.cfg"
  echo "Kept the printer's existing SAVE_CONFIG block."
else
  sed -n "/$marker/,\$p" "$main" >> "$staging/printer.cfg"
fi
for file in "${extras[@]}"; do
  cp "$file" "$staging/$(basename "$file")"
done

install -d -m 0750 -o klipper -g klipper "$dest"
backup="$dest/deploy-backups/$(date +%Y%m%d-%H%M%S)"
changed=()
for file in "$staging"/*.cfg; do
  name="$(basename "$file")"
  if ! cmp -s "$file" "$dest/$name"; then
    changed+=("$name")
    if [[ -f "$dest/$name" ]]; then
      install -d -m 0750 -o klipper -g klipper "$dest/deploy-backups" "$backup"
      cp -p "$dest/$name" "$backup/$name"
    fi
  fi
done
if (( ${#changed[@]} == 0 )); then
  echo 'Printer config already up to date.'
  exit 0
fi
for name in "${changed[@]}"; do
  install -m 0640 -o klipper -g klipper "$staging/$name" "$dest/$name"
done
echo "Updated: ${changed[*]}"
[[ -d "$backup" ]] && echo "Backup: $backup"

# Keep the five newest backups.
if [[ -d "$dest/deploy-backups" ]]; then
  find "$dest/deploy-backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tail -n +6 \
    | while IFS= read -r old; do rm -rf "${dest:?}/deploy-backups/$old"; done
fi

if (( ! restart )); then
  echo 'Apply with: sudo systemctl restart klipper'
  exit 0
fi

systemctl restart klipper
result=0
message="$(wait_klipper)" || result=$?
if (( result == 0 )); then
  echo 'Klipper restarted and is ready.'
elif (( result == 2 )); then
  echo 'Klipper restarted; not ready yet (printer off or still starting). Check Mainsail.'
elif grep -Eqi "mcu protocol error|unable to connect|lost communication|command format mismatch" <<<"$message"; then
  echo "Klipper cannot talk to the printer board: $message" >&2
  echo 'Not a config problem; if it mentions a protocol error, reflash the SKR firmware for this Klipper version.' >&2
else
  echo "Klipper rejected the new config: $message" >&2
  if [[ -d "$backup" ]]; then
    for name in "${changed[@]}"; do
      if [[ -f "$backup/$name" ]]; then
        install -m 0640 -o klipper -g klipper "$backup/$name" "$dest/$name"
      fi
    done
    systemctl restart klipper
    if wait_klipper >/dev/null; then
      echo 'Rolled back to the previous config; Klipper is ready.' >&2
    else
      echo 'Rolled back to the previous config, but Klipper is still not ready. Check Mainsail.' >&2
    fi
  else
    echo 'No previous config to roll back to.' >&2
  fi
  exit 4
fi
