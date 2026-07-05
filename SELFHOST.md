# Rhyolite Sync

End-to-end encrypted note & file sync built on a Δ-state CRDT engine —
conflict-free text merges (Fugue CRDT), LWW + conflict-copy for binary,
content-defined chunking, blobs the server never sees in plaintext.

This repository is the open (AGPL-3.0) part of Rhyolite: the sync **engine**,
the **self-host server**, and the **Obsidian client**. The managed multi-tenant
server, account/billing server, and promo server are proprietary and not
included here.

## Repository layout

```
packages/
  rhyolite_sync/                       # Δ-state CRDT sync engine (pure Dart)
  rhyolite_sync_server/                # pure sync responders (policy-free)
  server/
    rhyolite_sync_server_runtime/      # shared server composition (Postgres/MinIO/WS)
    rhyolite_sync_server_selfhost/     # self-host edition entry point
    rhyolite_observability/            # OpenTelemetry helpers
  client/
    rhyolite_client_obsidian/          # Obsidian plugin
    rhyolite_client_account/           # auth / subscription client contracts
    rpc_promo/                         # promo-code client contracts
docker-compose.yml                     # self-host stack (server + Postgres + MinIO + Caddy)
Caddyfile                              # TLS termination for wss://
.env.example
```

## Self-host the server

The server image is prebuilt and pulled from GHCR — nothing compiles locally.

```bash
git clone https://github.com/nogipx/rhyolite_sync.git
cd rhyolite_sync
cp .env.example .env
# set RHYOLITE_SYNC_TOKEN  ->  openssl rand -hex 32
# set SYNC_DOMAIN          ->  see TLS below
docker compose up -d
```

Clients connect to `wss://SYNC_DOMAIN` with the token as their bearer secret.
Postgres schemas and MinIO buckets are created on first run.

### TLS (`SYNC_DOMAIN`)

Caddy terminates TLS and reverse-proxies the WebSocket to the server. What you
set decides the certificate:

| `SYNC_DOMAIN`         | Certificate                              | Needs                        |
|----------------------|------------------------------------------|------------------------------|
| `sync.example.com`   | Real Let's Encrypt                       | Domain + ports 80/443 public |
| `<your-ip>.sslip.io` | Real Let's Encrypt (**no domain owned**) | Public IP + ports 80/443     |
| `localhost` / bare IP| Self-signed (Caddy internal CA)          | Clients must trust the root  |

No domain? `sslip.io` gets you a real cert: if your public IP is `203.0.113.5`,
set `SYNC_DOMAIN=203-0-113-5.sslip.io`. LAN/private only? Tailscale (`*.ts.net`,
real certs, no open ports) is smoother than trusting a self-signed root — the
desktop client can trust it, but the Obsidian plugin (Chromium) cannot without
importing the root CA into the OS trust store.

## Install the Obsidian plugin

Via [BRAT](https://github.com/TfTHacker/obsidian42-brat): add the beta plugin
URL `https://github.com/nogipx/rhyolite_sync`. Point it at your server in
Settings → Self-host (server URL `wss://SYNC_DOMAIN`, token = `RHYOLITE_SYNC_TOKEN`).

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE). You may run, study, modify, and
self-host this freely; if you offer it as a network service, the AGPL requires
you to make your modified source available to its users.
