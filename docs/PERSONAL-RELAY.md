# Personal vault relay synchronization

Mac is the authority for a personal vault. Native Android (8+) and iOS (16+) replicas retain their own encrypted databases, master passwords and offline edits. The browser extension continues to use its existing local native bridge. A browser write is journaled in the same transaction as its existing save receipt.

## Device groups and vault authorization

Native clients use common-relay's signed device-group protocol. The default endpoint is `wss://eglish.top/relay/v1/ws`; users may configure their own compatible WSS service. Self-service creation must be explicitly enabled for `passwordvault` on that service. A configured endpoint is not evidence that production registration is enabled.

1. Open **Settings → Relay sync → Device group** while unlocked. Enter a device name and create a named group, or scan/paste a trusted invitation. Phones and desktops have the same group-management capabilities; creating a group makes that device its first manager.
2. A manager selects **Add device** with **Join automatically after scanning** enabled by default. The encrypted short invitation lasts ten minutes and admits one ordinary member without further approval. Mobile scanners submit the invitation immediately; pasted invitations use the join button. Disable the option before creating an invitation to compare the twelve-hex-digit codes and approve manually; only manual approval can grant management permission (off by default). Cancel an active invitation before changing its mode. Failed automatic joins retain a retry draft.
3. Automatic invitations finish joining immediately; manual applicants select **Finish joining** after approval. The client validates the pinned manager signature, its own identity and the original request hash before saving membership. **Resend request** reuses the saved signed request after a lost response. Closing the page does not discard drafts or invitations.
4. Device-group membership authorizes relay access only. To synchronize vault contents, use the separate **Authorize vault sync** section: Mac creates a five-minute vault invitation; the phone reads it and returns a reply. Compare the eight-character vault code and authorize on Mac. Managed clients additionally require the peer's key to match the verified group roster. Joining a group alone does not initialize replication, trust every member or export any vault records.
5. Devices synchronize while their vaults are unlocked. Server delivery does not mean Mac committed a change. The pending counter clears only after a Mac receipt; pause and manual retry remain available.

The member list shows verified membership and online/offline presence at the last refresh. Offline devices remain listed. Anyone can rename themselves; managers can rename/remove other members. Group-management status does not change the Mac's business role as vault authority. Refresh is explicit on the settings page, and automatic before transport reconnect. A `group.changed` event triggers revalidation only for a newer revision; the welcome event for the already-verified revision must not cause a reconnect loop.

A 401 or signed removal/closure invalidates access, pauses synchronization and hides cached members/invitations. Network failure also hides the unverified management list but keeps recoverable configuration. Removing a member prunes matching local vault authorization before reconnect. Independently choosing **Unpair** revokes local vault authorization only, not server group membership.

### Leave, disband and migration

Leaving removes only this device; disbanding revokes the whole group. Each destructive action explains its scope and requires confirmation. The last manager cannot leave other members without management. Previously downloaded vault data cannot be remotely erased.

Exit requests are persisted before transmission and reused after response loss. After a confirmed exit, the app archives the encrypted core sync journal, retains the current vault and attachment blobs, clears local group access and rotates the relay device ID. The old journal preserves pending edits, conflict versions, tombstones and receipts for recovery; it is not reused in a new group. There is no archive-browsing UI in this increment. Normal vault backup/export includes current records, not these historical relay journals; preserve an encrypted whole-vault copy for forensic recovery. A newly authorized group starts a fresh baseline from the current document.

Existing manually provisioned credentials remain usable under **Legacy manual access**. They never silently become a signed managed group. Explicit migration clears only local access, archives the previous binding and creates a fresh relay device ID; an administrator must separately revoke old manual server credentials. Clearing an abandoned creation/join draft similarly cannot claim server-side revocation. Device identity private keys, master passwords and vault content are never included in invitation payloads. Automatic invitations contain a short-lived, scoped delegation secret; treat the entire link as an invitation credential and share it only with the intended device.

## Business protocol v1

Transport remains common-relay v1. No server business handlers are added; registration uses the existing signed group-management API. Swift and Java SDK snapshots are pinned in `vendor/common-relay/*/SOURCE.json` with the upstream commit and file checksums.

The native core exposes JSON commands through the existing UniFFI session: `relay-init`, `relay-status`, `relay-trust`, `relay-revoke`, `relay-export`, `relay-receive`, and `relay-resolve`, and `relay-detach`. They require an unlocked core session and are not exposed by the browser messaging allowlist. Application adapters bind the `peer` argument to the authenticated SDK sender, never a field supplied inside a packet.

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

## Automatic admission and compact invitation compatibility

All members must run an SDK that verifies delegated admission entries before automatic invitations are used. Older manual JSON invitations remain readable; missing `mode` means manual and is never silently upgraded. New QR codes use `common-relay://…/i/…#…`: the server stores an authenticated encrypted invitation packet, while its decryption key stays in the fragment. Resolution validates endpoint, invitation ID, application scope and expiry before creating a durable join request. Admission remains restricted to one ordinary member and does not grant vault synchronization authority. Swift and Java snapshots include the latest upstream automatic/compact invitation implementation plus durable preparation and `group.changed` forwarding; Java request timeouts remain compatible with API 26.
