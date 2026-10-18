# Personal vault relay synchronization

Mac is the authority for a personal vault. Native Android (8+) and iOS (16+) replicas retain their own encrypted databases, master passwords and offline edits. The browser extension continues to use its existing local native bridge. A browser write is journaled in the same transaction as its existing save receipt.

## Registration and pairing

1. Unlock each client and open **Settings → Relay sync**. Each client generates its own Curve25519 secret key. Copy only its public registration information.
2. Register each public key using the existing common-relay `device-add` command with application `passwordvault`, the same group for one Mac vault, and distinct device IDs. The relay administrator supplies the resulting credential JSON through a private channel. Private keys never leave the clients.
3. Enter the existing deployment's `wss://<host>/relay/v1/ws` endpoint and import the credential file. Import checks application and public-key identity. Mac creates a complete encrypted `before-personal-relay` snapshot before enabling replication. A mobile replica creates its snapshot when joining.
4. On Mac, create a five-minute invitation. Scan it on the phone (or paste its text). The phone displays a reply and an eight-character verification code. Copy the reply to Mac, compare both codes, and explicitly authorize it. The reply carries the phone's public key, never its token or secret key. The Mac challenge is single-use and expires on lock.
5. Devices synchronize while their vaults are unlocked. Close/lock pauses business processing; encrypted server delivery is not confirmation that Mac committed the change. The pending counter clears only after a Mac receipt. Pause and manual retry are available.

Mac unpairing removes the business authorization and pinned transport key. Administrators must additionally use common-relay `device-revoke` to revoke the server credential. Previously downloaded data cannot be remotely erased. A replica cannot silently switch to another Mac vault; its existing binding is checked.

## Business protocol v1

Transport remains common-relay v1. No server business handlers or automatic registration API are added. Swift and Java SDK snapshots are pinned in `vendor/common-relay/*/SOURCE.json` with the upstream commit and file checksums.

The native core exposes JSON commands through the existing UniFFI session: `relay-init`, `relay-status`, `relay-trust`, `relay-revoke`, `relay-export`, `relay-receive`, and `relay-resolve`. They require an unlocked core session and are not exposed by the browser messaging allowlist. Application adapters bind the `peer` argument to the authenticated SDK sender, never a field supplied inside a packet.

- The SQLCipher transaction stores the document and an additionally authenticated encrypted `personal_relay` journal together. Document format 4 prevents older clients from silently writing a synchronized vault; existing format 2/3 vaults upgrade only on opt-in.
- Mobile changes have stable operation IDs, record keys, base revisions and complete replacement values. Mac assigns monotonic revisions. A null record value is a permanent-deletion tombstone. Seen operation IDs reject changed-content retries.
- Each mobile request includes its applied cursor. Mac sends records newer than that cursor, revision metadata and committed operation receipts. Cursor zero requests a full baseline. Tombstones and deduplication metadata are retained in this first version; no unsafe pruning window is assumed.
- A mobile applies canonical records underneath its pending edits. Mac only accepts an edit against its expected base revision (or identical content). Concurrent changes become explicit conflicts. Mac can retain its version, accept the mobile version, or preserve both (copying item identities and attachment ownership, or combining categories). Pending edits remain until the corresponding operation is resolved and acknowledged.
- Replicated data includes items, categories, favorite/pin/trash state and rich-note attachment references. Theme, lock settings, credentials, master-password envelopes, browser grants and biometric configuration remain local. Legacy shared records retain their restrictions; relay pairing does not grant shared-vault editing rights.
- Attachment metadata and size limits are validated. Immutable attachment IDs cannot overwrite different bytes. All required files must validate before document/journal commit. Mobile rich notes retain their existing read-only editor policy. Attachment garbage collection is conservative while replication is enabled, retaining blobs needed for pending/conflicting versions.

Small packets use persistent offline messages; larger packets use the SDK's encrypted files. File staging contains an inner AES-GCM ciphertext; its random key is inside the SDK's encrypted metadata. No plaintext vault packet is written to a temporary file. Message transport IDs are deterministic per recipient, content and hourly retry epoch; business operation IDs remain unchanged across transport expiry. The receiver commits business data before acknowledging the SDK message or deleting the server file.

## Recovery and limits

The service has finite retention and quotas. Local changes remain authoritative pending work if server objects expire; retry sends the same business operations in a new transport envelope. Manual retry/reconnect also reconciles peers. Interrupted file uploads can leave expiring server objects; they do not clear the local pending work.

The pre-sync snapshot contains the encrypted database and header valid at activation. Recover it into a separate directory with the password valid at that time. Never replace a live vault or open a format-4 database with an old application. Regular backup/import remains explicit; restored records in an enabled vault enter the same transactional journal.

This version retains complete per-record values and unpruned receipt/tombstone metadata, so large histories require future bounded compaction. File serialization is bounded and in memory, consistent with the existing archive path; it is not a streaming database replication engine. Mac flushes active editors before applying incoming changes. Mobile replicas defer incoming application while an editor has an unfinished draft; save or discard the draft to resume. Mobile OS background execution is not guaranteed. Production distribution signing, real-device acceptance and independent security review remain separate gates.

See [validation](PERSONAL-RELAY-VALIDATION.md) for executed checks and remaining environment limitations.
