# Included by writeShellApplication. Never pass tokens in argv or echo them.
if (( EUID != 0 )); then
  echo 'Run: sudo homeserver-connect' >&2
  exit 1
fi
dir=/var/lib/homeserver/cloudflared
install -d -m 0700 "$dir"
umask 077
if (( $# )); then
  echo 'Usage: sudo homeserver-connect (paste token when prompted)' >&2
  exit 2
fi
if [[ ! -t 0 ]]; then
  echo 'Run from an interactive terminal (Cockpit terminal is supported).' >&2
  exit 1
fi
read -r -s -p 'Homelab tunnel token: ' token
printf '\n'
if [[ -z "$token" || "$token" =~ [[:space:]] ]]; then
  echo 'Paste only the non-empty token, not the installation command.' >&2
  exit 1
fi
envFile=/var/lib/homeserver/aiostreams/aiostreams.env
if [[ ! -f "$envFile" ]] || ! grep -Eq '^AIOSTREAMS_AUTH=.+:.+' "$envFile" || ! grep -Fxq 'AIOSTREAMS_AUTH_REQUIRED=true' "$envFile"; then
  echo 'Configure AIOStreams authentication in its protected env file before exposing the tunnel.' >&2
  exit 1
fi
tmp=$(mktemp "$dir/.token.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$token" > "$tmp"
unset token
chmod 600 "$tmp"
mv -f "$tmp" "$dir/token"
systemctl restart cloudflared.service
systemctl --no-pager status cloudflared.service
echo 'Connector started. Verify tunnel health in Cloudflare.'
