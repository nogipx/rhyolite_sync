# Rhyolite Sync

Syncs your vault across devices using end-to-end encryption.

> **An account is required for full access.**
> **Payment is required for full access** (subscription).

---

> [!WARNING]
> **Back up your vault before use.**
> This plugin modifies files in your vault during sync. Make a full backup of your vault folder before connecting for the first time or upgrading to a new version.

---

## Features

- **End-to-end encrypted sync** — your notes are encrypted on-device before being sent to the server. The server never sees plaintext content.
- **Multi-device support** — keep your vault in sync across desktop and mobile.
- **Lossless concurrent edits** — text files merge through a character-level CRDT; edits made simultaneously on multiple devices are preserved without conflict-copy files.
- **Passphrase-based encryption** — your encryption key never leaves your device.

## Requirements

For Rhyolite Cloud, use a [Rhyolite account](https://rhyolite.nogipx.dev). For self-hosting, use your server URL and token.

## Installation

1. In Obsidian, install and enable **BRAT** from Settings → Community plugins.
2. Open BRAT settings, choose **Add beta plugin**, and enter `https://github.com/nogipx/rhyolite_sync`.
3. Enable **Rhyolite Sync** in Community plugins.
4. Open the plugin settings. For Rhyolite Cloud, sign in and connect your vault. For a self-hosted server, enter the server URL and token.
5. Enter your vault passphrase.

## Network services

This plugin connects to the **Rhyolite Sync backend** (hosted at `rhyolite.nogipx.dev`) for the following purposes:

| Service            | Purpose                                             |
|--------------------|-----------------------------------------------------|
| Authentication     | Account sign-in and session management              |
| Vault sync         | Uploading and downloading encrypted file changes    |
| Subscription check | Verifying active subscription status                |

No plaintext note content is ever sent to the server. All data is encrypted on your device using your passphrase before transmission.

## Privacy

See our [Privacy Policy](https://rhyolite.nogipx.dev/privacy) for full details on data collection and handling.

### File system access

The plugin reads and writes **only** inside the vault folder Obsidian opens it for. It does not access user files anywhere else on disk.

Where the different pieces of state live:

| Data | Storage |
|---|---|
| Note content (your files) | The vault folder, as you'd expect |
| Sync metadata (cursors, CRDT state, blob cache) | SQLite database kept by the WASM runtime in the host's local storage (IndexedDB on desktop and mobile). Not exposed as files in the vault. |
| Auth tokens (session, refresh) | Obsidian's secret storage (`Plugin.loadData`/secret APIs). Never written to `data.json` or files on disk. |
| Encryption key (derived from your passphrase, only when "Remember on this device" is on) | Obsidian's secret storage. Cleared on sign-out or disconnect. |
| Plugin UI configuration (vault id, last-used server URL) | `.obsidian/plugins/rhyolite_sync/data.json` |

### Telemetry

Diagnostics are local by default. To stream logs from multiple devices on the same Wi-Fi, run `just log-collector` on the development machine. On each device, open the plugin's **Diagnostics** settings, enter the collector URL printed for that platform, then enable **Send logs to collector**. On macOS, install `mkcert` and `caddy` and run `mkcert -install` once. On iOS, install the public `rootCA.pem` from `mkcert -CAROOT` as a profile, then enable full trust in Certificate Trust Settings.

Connect an MCP client on the collector machine to `http://127.0.0.1:9501/mcp`. Call `rpc_log_sources` to see connected devices and their labels. Call `rpc_log_get_logs` with a `device` label to isolate one connection, or with `traceId` to follow a traced operation. Pass the returned cursor on the next call to read newer records.

## Bundled native components

The plugin ships with one external binary in addition to the compiled JavaScript:

### `sqlite3mc.wasm`

A WebAssembly build of **[SQLite3 Multiple Ciphers](https://github.com/utelle/SQLite3MultipleCiphers)** (sqlite3mc) — an SQLite extension that adds AES-256 encryption to the SQLite engine. It is used for local-only state storage:

- Sync engine metadata (server cursor, epoch, last-seen state per file)
- Fugue CRDT sequences for text files (per-character history used to merge concurrent edits losslessly)
- Local blob cache (chunked file content, encrypted at rest by your passphrase)

The WASM module exports its **linear memory** — this is the standard interface SQLite uses to read and write its database pages on disk. It is not a sign that the module is loading or running arbitrary code; the export exists because the host environment (the plugin's compiled JS) needs to hand SQLite buffers of bytes.

The bundled `.wasm` binary corresponds to a published release of the [`sqlite3.dart`](https://github.com/simolus3/sqlite3.dart/releases) package, which builds sqlite3mc reproducibly from the upstream C source. The wasm file is shipped here so the plugin works offline without downloading it at runtime.

License: sqlite3mc is dual-licensed under the [MIT License](https://github.com/utelle/SQLite3MultipleCiphers/blob/master/LICENSE) and the SQLite Public Domain license.

## Build provenance

The sync engine is written in [Dart](https://dart.dev) and compiled to JavaScript via `dart2js`; the Obsidian shell around it is TypeScript, bundled with esbuild. Both halves are concatenated into the single `main.js` shipped with each release, built in a private CI from a private source tree.

Each release lists the **SHA-256 of `main.js`** and a link to the CI workflow run that produced it in the release notes. You can verify the binary you install matches that hash with `shasum -a 256 main.js`.

## FAQ

**Does it work on mobile (iOS/Android)?**
Yes, the plugin works on both desktop and mobile.

**Do I need to enter my passphrase on every device?**
Yes, once per device when connecting to a vault. After that, you can enable "Remember on this device" to store the derived key in Obsidian's secret storage — so you won't be prompted again on subsequent launches.

**What happens if I forget my passphrase?**
Your local files on disk are not affected — they are never deleted by the plugin. If you forget your passphrase, you lose access to the encrypted copies stored on the server, but your original notes remain intact on every device where they exist. The passphrase is never sent to the server and cannot be recovered, so store it somewhere safe.

**Can I change my passphrase?**
Not currently supported.

**What happens to my files if I disconnect the vault?**
Files on disk are not affected. The plugin removes the vault configuration and remembered key from the device. Your data on the server remains intact.

**What happens to my data on the server if I cancel my subscription?**
Your data is not deleted from the server when a subscription expires. Sync will stop until the subscription is renewed.

**How are concurrent edits handled?**
Text files (`.md`, `.txt`, `.json`, `.canvas`, and similar) sync through a character-level CRDT. Edits made simultaneously on different devices merge losslessly — there is no winner-takes-all step and no conflict-copy file. If you and another device both type into the same paragraph, both edits are preserved.

Binary files (PDFs, images, attachments) use a Last-Write-Wins strategy. When two devices modify the same binary concurrently, the version with the later timestamp becomes the canonical one, and the other is saved alongside it as `filename (conflict YYYY-MM-DD).ext` so nothing is lost.

## License

This plugin is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

## Support

- Website: [rhyolite.nogipx.dev](https://rhyolite.nogipx.dev)
- Telegram: [t.me/nogipx](https://t.me/nogipx)
- Issues: open a GitHub issue in this repository
