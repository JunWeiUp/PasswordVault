# Architecture

The repository is migrating to a shared Rust core and native clients. Current implementation and scoped acceptance are documented in [NATIVE-MIGRATION.md](NATIVE-MIGRATION.md).

## Native V2 architecture

- `crates/vault-core`: Argon2id/AES-GCM envelopes, SQLCipher persistence, compatibility readers, records/TOTP/wallet utilities, and authenticated V2 sharing. UniFFI exposes an actor-serialized command boundary to Swift; WASM exposes the same document model to the browser.
- `apps/macos`: SwiftUI views and AppStore, a locally bundled Milkdown/WKWebView Markdown editor, Keychain biometric gate, file dialogs, camera/QR, ephemeral WebDAV, LAN WebSockets, and a signed Unix-socket native-messaging bridge. Editor integration has its own acceptance gate.
- `apps/browser`: small Preact popup and separate full workspace, MV3 worker, on-demand top-frame fill/read script, default-on login submit listener with per-site disable exceptions and matching-account badges with ephemeral pending credentials, disposable KDF worker, and encrypted IndexedDB compare-and-swap storage.
- Native data uses a fresh random root key. The master password wraps that root with a salted Argon2id-derived key. Separate HKDF domains protect SQLCipher storage, the document, and recovery drafts. Password changes atomically replace only the wrapped-root header.
- Browser data is an authenticated encrypted whole-document bundle. Lock clears the active engine. Master passwords and root keys have no persistent browser storage path.
- Unknown record fields survive round trips so legacy accounts/history can be carried forward. Old backup readers are read-only; V2 is the only new encrypted writer. New synchronization is a separately versioned protocol.

### Local Mac note editor

`apps/macos/NoteEditor` pins Milkdown 7.22.2 and uses its CommonMark/GFM presets and ProseMirror history. `build.mjs` bundles JavaScript/CSS into `Resources/NoteEditor.html` and generates dependency license notices. The app loads this static resource into a WKWebView with a nonpersistent website data store. Markdown is passed through `callAsyncJavaScript` arguments after initialization; note contents are never interpolated into the HTML resource or written to a web-storage database. The editor receives note text and interaction state, not vault keys or a general core-command API.

`MarkdownNoteEditor.swift` owns a per-note session/lease. Messages carry a session token and change revision; native handling requires the main frame and a registered, non-closing session. AppStore independently checks the current note and write permission. A native configuration echo may update display mode/language without replacing the document; differing source is applied only when the editor revision and composition state permit it. Opening an unchanged note retains its original source. Actual edits serialize the ProseMirror document to Markdown and enter the existing encrypted debounce/recovery path.

Before source editing, `prepareNoteSource` retires the rendered editor and awaits its final DOM/composition snapshot. A replacement web editor also waits for the previous lease. Closing hides the web view, stops accepting change messages, destroys its DOM/history and removes message handlers; the acknowledged source and close result survive until the store consumes them. Lock hides record UI immediately, collects final snapshots under the captured note/permission baseline, then calls the core's encrypted pending-write/lock path. Snapshot failure preserves the last acknowledged record and blocks an export that would claim a complete current snapshot. It is not permission to save an empty document.

The generated CSP allows only the bundled hash-authorized script and inline local styles; connection, image, media, font, frame, base and form destinations are denied. Native navigation permits the local blank document only. User-confirmed HTTP(S)/mailto links open through a native menu, outside the editor. These restrictions and `.nonPersistent()` do not establish complete memory erasure: decrypted text necessarily exists in Swift/JavaScript/WebKit memory while editing. Failure, composition, network and teardown behavior require the [editor verification](DEVELOPMENT.md#local-mac-note-editor) checks; the new editor has no inherited device/security acceptance from its predecessor.

## Legacy architecture retained during migration

The existing legacy client is a local-first Flutter application. Android, iOS, Web, and the Chromium extension share Dart feature code; native integrations and browser bridges supply platform behavior. Platform validation status is recorded in [PROJECT-SPEC.md](PROJECT-SPEC.md).

## Layout

| Path | Responsibility |
| --- | --- |
| `lib/core/database` | Drift schema, migrations, native and WASM connections |
| `lib/core/security` | Encryption and platform secret storage |
| `lib/core/l10n`, `lib/l10n` | Locale selection, messages, generated accessors |
| `lib/core/theme`, `lib/core/widgets` | Shared visual theme and reusable presentation components |
| `lib/features/vault` | Vault UI, repository, sharing, password health |
| `lib/features/totp` | Authenticator engine and code cards |
| `lib/features/backup` | WebDAV backup and restore |
| `lib/features/sync` | Local discovery, sync endpoints, sharing protocol |
| `chrome` | Manifest V3 worker, content script, translations |
| `web` | Flutter web shell and Drift WASM assets |
| `tool` | Portable repository and release checks |

Riverpod owns application state; GoRouter handles navigation. The internal package name `password`, Android ID `com.securepass.vault`, and existing storage identifiers are retained to avoid breaking data compatibility.

`lib/main.dart` initializes the app and router; `vault_workspace_page.dart` owns responsive navigation, search, lists, and settings. The workspace uses side navigation from 840 logical pixels and bottom navigation below that width. See [PAGE-STRUCTURE.md](PAGE-STRUCTURE.md) for interaction details and [images/README.md](images/README.md) for source-rendered screenshot reproduction.

## State and data flow

`main.dart` initializes Flutter, a Riverpod `ProviderScope`, localized themes, and GoRouter. `AuthGuard` observes the master-password provider before showing protected screens. Feature providers coordinate the vault repository, TOTP engine, backup, and sync services.

Vault reads and writes pass through `VaultRepository`, which maps domain objects to Drift records and handles protected fields with the encryption service. Drift owns the database schema and platform connection. Browser extension helpers bridge Dart code to the extension scripts; Android autofill is implemented in the native runner.

| Boundary | Source |
| --- | --- |
| Domain records | `lib/features/vault/domain/models/vault_item.dart` |
| Repository and encryption | `lib/features/vault/data/repositories/vault_repository.dart`, `lib/core/security/` |
| Application and authentication state | `lib/core/providers/`, `lib/features/vault/presentation/providers/` |
| Browser integration | `lib/core/extension/`, `chrome/background.js`, `chrome/content.js`, `chrome/bridge.js` |
| Native integration | `android/app/src/main/`, `ios/Runner/` |

## Data organization

The Drift schema in [`app_database.dart`](../lib/core/database/app_database.dart) is version 12. `VaultItems` stores entries and their metadata, `SharedVaults` stores vault identity and wrapped keys, and `SharedMembers` stores membership, roles, and member-specific wrapped keys. `VaultItemType` retains the persisted order `password`, `totp`, `crypto`, `secureNote`.

Native connections open `db.sqlite` in the application documents directory; Web connections use the database name `secure_pass_db` with `sqlite3.wasm` and `drift_worker.js`. These are compatibility identifiers, not branding strings. Protected fields are encrypted at the application layer; metadata and platform secret-storage behavior have separate limits described in [SECURITY_MODEL.md](SECURITY_MODEL.md). Do not infer whole-database encryption or a secure unlock design from the storage engine alone.

## Data compatibility

Do not rename stored category strings, protocol fields, app IDs, salts, or database names as part of a translation. Changes to master passwords, key derivation, and encrypted backups need migration tests using disposable fixtures. Never use a developer's real vault as a test fixture.

When updating Drift/sqlite3, run `python3 tool/update_sqlite_wasm.py` to download the matching upstream WebAssembly asset and verify its package-published checksum. Commit the updated binary and regenerated worker. CI and extension builds reject mismatched assets.


## Native mobile clients

`apps/ios` contains the SwiftUI app and Credential Provider extension sharing an App Group. Background lock closes the exclusive core session before an extension can open it. `apps/android` contains Compose UI, a Keystore adapter, Autofill service/authentication activity and a separate login QA module. Generated UniFFI bindings and ABI-specific libraries are rebuilt with `tool/build_mobile_core.sh`; they are ignored build products. Both clients use the existing Rust vault/backup/share schema. See [mobile acceptance](MOBILE-IMPLEMENTATION.md) for migration and platform gates.

### Browser offline credential staging

Background saving uses the existing short-lived native messaging helper, not a resident daemon. It verifies the Mac master password against the existing header and stores a native-only root capability in its login-Keychain entry, bound to the header fingerprint and a revocation epoch. The extension stores only a random capability identifier. The helper strips any browser-supplied native grant before constructing its authenticated IPC envelope.

With the desktop active, the signature-checked socket routes append-only requests through its CoreClient actor and Rust session mutex. With no desktop socket, the helper opens a short-lived VaultSession under the same exclusive process lock. Lock contention retains the browser queue for retry; desktop startup also retries briefly. No process independently opens a second writable session. A locked desktop session temporarily opens the core for this append and relocks before returning; the UI and read/fill APIs remain locked.

Confirmed captures stay in the AES-GCM IndexedDB queue until the native durable acknowledgement. The envelope ID becomes an idempotency key in a SQLCipher receipt table committed in the same transaction as the encrypted document; even a retry after deletion cannot resurrect an acknowledged record. Exact existing credentials are skipped, differing passwords append separate items. Without background authorization, the prior paired/unlocked delivery remains available. A one-minute MV3 alarm exists only while native-mode records are queued. Status checks do not instantiate the database core or run Argon2. See [background saving](BROWSER-OFFLINE-SAVE.md).


### Scoped browser access and desktop startup

Browser 2.2.9 / Mac 2.0.12 adds explicit read/startup scope flags to the helper-owned Keychain envelope; raw legacy grants decode as save-only. A separate Keychain index points to the most recently enabled startup owner. Matches/fill use a narrow native API that restores a previously locked core after each call, while the existing append path and durable receipts are unchanged.

At cold start, AppStore creates an in-memory, single-use nonce and invokes the helper's desktop-only mode. The helper verifies the parent's desktop code signature and returns the grant only over the signed-peer socket. Browser-mode requests cannot enter that operation. AppStore consumes the nonce once; lock clears it and increments the existing lifecycle epoch. Reopening a window or status polling never starts a second attempt. See [authorization protocol and evidence](BROWSER-AUTHORIZATION.md).
