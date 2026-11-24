# Compatibility helper: same encrypted backend as Cockpit.
if (( EUID != 0 )) || (( $# )) || [[ ! -t 0 ]]; then
  echo 'Usage: sudo homeserver-connect (interactive)' >&2
  exit 1
fi
read -r -s -p 'Homelab tunnel token: ' token
printf '\n'
printf '%s' "$token" | python3 -c 'import sys,json; print(json.dumps({"name":"CLOUDFLARE_TUNNEL_TOKEN","value":sys.stdin.read()}))' | /run/current-system/sw/bin/homeserver-secrets set
unset token
