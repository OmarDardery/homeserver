# Run by homeserver-update.service as root (started from Cockpit → Secrets).
# 1. Refuses while a print is active or paused.
# 2. Makes sure GitHub holds this server's encrypted secrets (publishes if
#    missing; stops if GitHub has different ones).
# 3. Runs the installer from GitHub: rebuilds NixOS, deploys the printer
#    config and restarts Klipper.
if state="$(curl -fsS --max-time 3 'http://127.0.0.1:7125/printer/objects/query?print_stats=state' 2>/dev/null)"; then
  if grep -Eq '"state": *"(printing|paused)"' <<<"$state"; then
    echo 'A print is active or paused; not updating.' >&2
    exit 1
  fi
fi

echo '==> Checking encrypted secrets against GitHub'
homeserver-secrets github-ensure

# The repository is private: reuse the Cockpit GitHub token for this fetch only.
nix_config='experimental-features = nix-command flakes'
token_file=/var/lib/homeserver/secrets/github.token
if [[ -s "$token_file" ]]; then
  nix_config+=$'\n'"access-tokens = github.com=$(<"$token_file")"
fi

echo '==> Fetching github:OmarDardery/homeserver and running the installer'
NIX_CONFIG="$nix_config" nix run --refresh github:OmarDardery/homeserver
echo '==> Update complete'
