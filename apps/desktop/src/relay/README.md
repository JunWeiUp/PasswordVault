# Native Shell relay port

The app now has device-group orchestration, presence, explicit vault authorization
and replication. Protocol primitives are adapted from the vendored CommonRelay
Swift SDK, copyright JunWeiUp, under its [MIT license](../../../../vendor/common-relay/swift/LICENSE).
Automated local tests use loopback services and synthetic vaults. A separate, explicitly
authorized production run verified admission and WSS with disposable vaults and a
test group that was disbanded afterward; no real user vault was accessed.

## Implemented

- Group creation with durable retry drafts; encrypted compact invitation links with
  automatic/manual admission; delegated signature/anchor verification; manual join
  requests and matching verification codes; ordinary/manager approvals; invitation
  cancellation; rename/remove; leave/disband. Exiting invokes core `relay-detach`
  to archive the encrypted journal before clearing access and rotating the device ID.
- Strict signed JSON parsing, pinned membership chains, NaCl box context binding,
  Ed25519 signatures and XSalsa20-Poly1305 invitation encryption. Unknown or
  ambiguous signed fields, changed identities, bad anchors and unauthorized
  transitions fail closed. Server keys never establish trust.
- One Rust connection owner per unlocked vault, rustls WSS/native roots, checked
  welcome identity/subprotocol, bounded frames and timeouts. Roster queries run
  every five seconds; reconnect backs off from one to thirty seconds. Lock stops
  the socket synchronously, including an in-progress TLS handshake. Group HTTP
  requests have deadlines and never follow redirects.
- Separate `passwordvault.access.v1` set/ack messages, pinned member public keys,
  increasing revisions, pending confirmation and local-first revocation. Membership
  alone never permits export. A mobile-role configuration pins its unique verified
  manager as authority; messages cannot replace that pin.
- Core `relay-*` and existing `relay-peer-*` routing. Small offline messages have
  deterministic IDs and an encrypted durable delivery journal. Business changes
  commit before ACK. Replay, expiry, stale grants and identity mismatches cannot
  restore access. Peer packets above 128 KiB use the existing 64 KiB chunk protocol,
  bounded to 48 MiB per assembled packet.
- Large legacy packets use CommonRelay secretstream file framing and encrypted
  metadata, with the same inner AES-GCM combined format as CryptoKit. Uploads
  validate resumable offsets/descriptors; downloads use bounded ranges and verify
  hashes/final tags before decrypting. The ciphertext limit is 768 MiB. The current
  Rust implementation buffers the complete encrypted file and inner packet in
  memory; near-limit transfers still need memory/performance acceptance.
- Settings status, group management, invitation QR drawn from a Rust matrix,
  authorization toggles, pending ACK display, legacy conflict compare/atomic batch
  choice, and per-key peer-library conflict resolution. Format 7 explicitly shows
  `DevicesSyncBlocked`; export/receive/trust/init remain blocked. Revocation and
  archival detach use the core's explicit safe exceptions.

## Server access and invitation images

Creation requires the relay access password. A rejected creation preserves its signed
draft; entering a corrected password retries the same identity and group. HTTP and
WebSocket requests send `Relay-Access`; credentials remain encrypted at rest.
Joining accepts a typed password or the optional password carried in a short
invitation fragment. The fragment is base64url encoding, not encryption: recipients
of the full link also receive the relay access password.

The NSH `Picker.pickImages` component selects an invitation QR image. Rust decodes
and validates it locally, bounded to 20 MiB, 8192 pixels per side and 128 MiB of
image allocation. Invalid/ambiguous invitations fail before any network request.
The decoded link is masked and requires an explicit Join action. Cancelling the
picker preserves the existing input. This is image recognition, not a live camera
or screen scanner; the current NSH runtime has no built-in camera scanning component.

## Storage and lifecycle

Identity secrets, tokens and group drafts remain in core
`relay-private/credentials.v1.enc`; the Swift Codable base64 `groupState` is
preserved. Replay records live in `relay-private/nsh-journal/*.enc`, separately
secretbox-encrypted with a domain-separated key derived only while the credential
store is unlocked. Filenames and encrypted envelopes bind group/device/sender/id.
Writes use mode 0600, atomic replacement and fsync; the directory is mode 0700.
Symlinks and corrupt records are rejected. Records retain seven-day receipt
history; pending transport bodies expire after one day. No vault plaintext is
written to staging files, logs or the journal. Outgoing plaintext queues are
zeroized when dropped on lock/reconnect.

Only display state crosses to TSX. The issued invitation link is deliberately
returned as a sensitive sharing capability for its QR/copy UI. Private identity
keys, relay tokens, delegation secrets and credential JSON never cross that API.

## Integration

Settings.tsx (owner-managed):

```tsx
import { RelayPage } from "./relay";
// PAGES:
relay: RelayPage,
```

Sidebar footer: import `syncStatus` from `./relay` and render `{syncStatus()}`.
The relay module subscribes to `phase` and `onLock` itself; it starts on unlock
and stops on lock. `relayOnLock()` is also exported if the owner wants an earlier
lock hook. `refreshRelay()` refreshes local summaries; committed incoming changes
refresh the store. Stale asynchronous summaries are discarded after lock.

TS exports: `RelayPage`, `syncStatus()`, `refreshRelay()`, `relayOnLock()`,
`InvitationQR({link})`, `relayErrorText(error)`, `RELAY_UPGRADE_MESSAGE`.

Native APIs from `passwordvault/native`:

- `Relay.action(vault, requestJSON): Promise<string>`: create, refresh, invite,
  join, retry-join, finish-join, check-request, approve, cancel-invitation, rename,
  remove, leave, disband, clear-local. Returns display JSON; requests never accept private keys.
- `Relay.authorize(vault, peer, enabled): Promise<void>` and
  `Relay.pause(vault, paused): Promise<void>`.
- `Relay.connect(vault)`, `Relay.disconnect(vault)`, `Relay.syncNow(vault)`.
- `Relay.connectionStatus(vault): string`, `Relay.summary(vault): Promise<string>`.
- `Relay.invitationImage(bytes): Promise<string>`: bounded local invitation QR decoding.
- `Relay.qr(text): string`: JSON boolean matrix including a four-module quiet zone.

## Deliberate compatibility gates

- Legacy manually imported credentials without a verified group chain require
  explicit migration in the existing SwiftUI app (`LegacyRelayResetRequired`), or
  the confirmed local-only reset before fresh enrollment. That reset does not claim
  server-side credential revocation.
  This port never silently bootstraps trust from a server or replaces that identity.
- Existing explicitly enrolled peer libraries replicate and resolve conflicts.
  Creating/authorizing a **new** peer-library identity still needs its separate
  identity-receipt workflow; the device-group switch cannot grant that authority
  (`PeerLibraryIdentityRequired`). Its enabling control remains disabled.
- No generic CommonRelay interactive binary-stream API is exposed. PasswordVault's
  shipping adapter uses offline messages, peer chunks and secretstream HTTP files;
  those paths are implemented. Unrequested binary frames fail closed.
- Format 7 remains blocked for data sync until signed capability negotiation is
  implemented. Merely upgrading both clients does not bypass that gate.

## Validation and remaining live checks

Run from the repository root with a fresh copy of the synthetic seed:

```sh
PASSWORDVAULT_VAULT_DIRECTORY=/tmp/<synthetic-copy>/vault bash tool/nsh_mac.sh check
PASSWORDVAULT_VAULT_DIRECTORY=/tmp/<synthetic-copy>/vault bash tool/nsh_mac.sh test --filter relay
```

Focused coverage includes both vendor protocol-vector files (15 strict-payload
negative cases and nine delegated-admission negative cases), credential lock and
at-rest canaries, invitation tampering, actual loopback HTTP group lifecycle,
WebSocket reconnect/presence/lock shutdown, grant/ACK/item replication/revocation,
format-7 refusal plus detach, peer chunk replication and identity rejection,
secretstream corruption/truncation and HTTP upload resume/range download,
encrypted replay recovery/conflicting IDs, and headless UI mode/code/lock gates.
The admission/image update passed 52 Rust tests and four focused headless UI tests,
plus Rust/TypeScript checking. The final full NSH run passed 75 tests with no failures.
The test wrapper also rejects a missing temporary-vault path or a normal user-data path. Separate production component runs verified incorrect
password rejection, corrected-draft creation, creator WSS, invitation QR auto-password
join and WSS, old-link rejection without password, manual-password join, and group
disband. The NSH picker response was injected by the headless driver; native dialog,
visual window and physical camera interaction were not tested. Private redacted
evidence lives in `private/notes/relay-access-qa/` and must not be published.

Still unverified: WSS certificate/proxy environments beyond the tested deployment; current Swift/Java
clients exchanging dynamically generated invitations, grants, receipts and files;
manual camera QR scanning; lost HTTP responses at every enrollment/exit boundary;
long-running offline expiry/restart under actual server retention; phone background
transitions; simultaneous multi-device conflicts; near-768-MiB file memory use;
and native-window/VoiceOver interactions. Run those on a dedicated test relay with
synthetic vaults. Compilation and loopback tests are not production-security or
physical-device acceptance.
