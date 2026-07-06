#!/bin/bash
#
# Rhyolite self-host installer.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/nogipx/rhyolite_sync/main/install.sh)"
#
# Downloads the compose stack, generates a sync token, and starts the server.
# Unattended:  SYNC_DOMAIN=sync.example.com RHYOLITE_YES=1 bash -c "$(curl ...)"
#
set -euo pipefail

RAW="https://raw.githubusercontent.com/nogipx/rhyolite_sync/main"
DIR="${RHYOLITE_DIR:-$(pwd)/rhyolite-selfhost}"
DOMAIN="${SYNC_DOMAIN:-}"
YES="${RHYOLITE_YES:-}"

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

gen_token() {
  if have openssl; then openssl rand -hex 32
  elif have python3; then python3 -c 'import secrets;print(secrets.token_hex(32))'
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

have docker || die "docker not found — install Docker first"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"

say ""
say "Rhyolite self-host installer"
say ""
say "This will:"
say "  - create        $DIR"
say "  - download      docker-compose.yml + Caddyfile"
say "  - generate      a sync token (reused if one already exists)"
say "  - start         postgres + minio + sync + caddy (docker compose up -d)"
say ""

if [ "$YES" != "1" ] && [ -e /dev/tty ]; then
  printf "Press Enter to continue, Ctrl-C to abort... "
  read -r _ </dev/tty || true
  say ""
fi

mkdir -p "$DIR"
cd "$DIR"

curl -fsSL "$RAW/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$RAW/Caddyfile"          -o Caddyfile

if [ -f .env ] && grep -q '^RHYOLITE_SYNC_TOKEN=' .env; then
  say "Reusing existing token from $DIR/.env"
else
  if [ -z "$DOMAIN" ] && [ "$YES" != "1" ] && [ -e /dev/tty ]; then
    printf "SYNC_DOMAIN (blank = localhost, self-signed): "
    read -r DOMAIN </dev/tty || true
  fi
  DOMAIN="${DOMAIN:-localhost}"
  {
    printf 'RHYOLITE_SYNC_TOKEN=%s\n' "$(gen_token)"
    printf 'SYNC_DOMAIN=%s\n' "$DOMAIN"
  } > .env
fi

mkdir -p data/postgres data/minio data/caddy/data data/caddy/config
docker compose up -d

TOKEN="$(grep '^RHYOLITE_SYNC_TOKEN=' .env | cut -d= -f2-)"
DOMAIN="$(grep '^SYNC_DOMAIN=' .env | cut -d= -f2-)"

say ""
say "Rhyolite self-host is running."
say "  dir:    $DIR"
say "  url:    wss://$DOMAIN"
say "  token:  $TOKEN"
say ""
say "Point your client at the url above with the token as its bearer secret."
say "Stop:   (cd $DIR && docker compose down)     # data in ./data survives this"
say "Backup: (cd $DIR && tar czf backup.tgz data)"
say "Logs:   (cd $DIR && docker compose logs -f sync)"
