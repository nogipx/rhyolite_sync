# Sync a folder without Obsidian

Run these commands on the Linux server or NAS that holds the folder. You need Docker Compose and your vault's encryption passphrase. The container connects to Rhyolite Cloud or your own server over an outbound connection.

## Set up the folder

Run as the user who owns the notes. Keep the state and secrets directories outside the vault.

```sh
mkdir -p ~/rhyolite-headless
cd ~/rhyolite-headless
curl -fLO https://raw.githubusercontent.com/nogipx/rhyolite_sync/cli-1.0.1/headless/compose.yaml
mkdir -m 700 -p state secrets
printf 'RHYOLITE_UID=%s\nRHYOLITE_GID=%s\nVAULT_PATH=/absolute/path/to/notes\n' "$(id -u)" "$(id -g)" > .env
touch secrets/passphrase && chmod 600 secrets/passphrase
```

Set `VAULT_PATH` in `.env` to your existing notes directory. Enter your vault passphrase in `secrets/passphrase` using a text editor.

**Rhyolite Cloud.** Sign in once, then select the vault during the first sync.

```sh
docker compose run --rm sync login
docker compose run --rm sync sync
docker compose up -d
```

**Your own server.** Save the server token in `secrets/token` and run `chmod 600 secrets/token`. Replace the `command` line in `compose.yaml` with the following, using your server URL and existing vault ID.

```yaml
    command: ["daemon", "--selfhost", "--server-url", "wss://sync.example.org", "--token-file", "/secrets/token", "--vault-id", "YOUR_VAULT_ID"]
```

Run `docker compose up -d`. Create a note in Obsidian and check that it appears in the mounted directory. Edit it there and check the change in Obsidian. See progress with `docker compose logs -f sync`. Keep `state/` across upgrades so the client remembers its vault, session and sync progress.

## Install without Docker

Download version 1.0.1 for your platform.

| | x64 | arm64 |
|---|---|---|
| Linux (glibc) | [Download Linux x64](https://raw.githubusercontent.com/nogipx/rhyolite_sync/cli-1.0.1/headless/downloads/rhyolite-1.0.1-linux-x64.tar.gz) | [Download Linux arm64](https://raw.githubusercontent.com/nogipx/rhyolite_sync/cli-1.0.1/headless/downloads/rhyolite-1.0.1-linux-arm64.tar.gz) |
| macOS | [Download Intel](https://raw.githubusercontent.com/nogipx/rhyolite_sync/cli-1.0.1/headless/downloads/rhyolite-1.0.1-macos-x64.tar.gz) | [Download Apple Silicon](https://raw.githubusercontent.com/nogipx/rhyolite_sync/cli-1.0.1/headless/downloads/rhyolite-1.0.1-macos-arm64.tar.gz) |

[SHA-256 checksums](https://raw.githubusercontent.com/nogipx/rhyolite_sync/cli-1.0.1/headless/downloads/SHA256SUMS). Extract the entire archive into one directory and run `./bin/rhyolite --help` there. Linux needs `libsqlite3.so` (on Debian or Ubuntu, install `libsqlite3-dev`).

For Cloud, run `./bin/rhyolite login --vault-path /path/to/notes` once. Then run `./bin/rhyolite daemon --vault-path /path/to/notes --passphrase-file /path/to/passphrase` for continuous sync, or replace `daemon` with `sync` for one pass. The passphrase file must be readable only by its owner.
