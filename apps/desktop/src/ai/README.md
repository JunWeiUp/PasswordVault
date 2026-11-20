# Local AI access (Native Shell preview)

The app owns policy and the live `VaultSession`. `pv-mcp` is a stdio MCP adapter
and script CLI, with **no vault access**. It sends one bounded JSON line per local
Unix-socket connection. Both ends check the peer UID (`getpeereid`); the socket
uses mode 0600 inside a private 0700 directory at the fixed path
`~/Library/Application Support/PasswordVaultNSHPreview/ai/mcp.sock`, so client
configurations survive app restarts. Startup is serialized with a lock; a live socket is
never replaced, and a stale one is removed only when it belongs to the same owner, refuses
connections and its inode/device are unchanged. Tests override the path with
`PASSWORDVAULT_AI_SOCKET`. The socket is separate from the browser bridge.
Same-UID checks do not authenticate an executable's identity. The random client
bearer token is the second boundary. Protect client configuration accordingly.

## Pair and configure

1. Unlock the app, enable AI access, and enable the desired category scopes.
2. In the top-pinned **AI 访问** view, enter a client name (and optional remark stored in
   encrypted `settings.uiPrefs.aiClientNotes`) and press **复制给 AI**. The app creates the
   client (control-plane `pair`, never reachable through the socket) and copies a short
   instruction plus a ready MCP configuration that already contains the token. The token
   is shown only in that clipboard payload (cleared after 30 seconds) and never in audit.
   Paired clients expose a deterministic non-secret `fingerprint` (never `tokenHash`),
   support temporary pause/resume (`set_paused`, rejecting MCP calls with `ClientPaused`
   while preserving the token), and atomic batch revoke (`revoke_many`).
3. Enabled category scopes (`accounts`, `profiles`, `devices`, `notes`, `noteAssets`) apply
   directly to all paired clients without per-item manual whitelisting; individual entries
   can be hidden via the per-entry exclusion list (`aiAccessExcludedEntries`). Ordinary
   fields are readable in plain text; only passwords, card numbers/CVV, private keys,
   tokens, concealed custom fields and secret device commands go through `read` with `field`
   approval. Binary note asset text extraction additionally requires the per-attachment
   `AI 可读文本` toggle (`aiAccessNoteAssetText`).

```json
{
  "mcpServers": {
    "passwordvault": {
      "command": "/path/to/pv-mcp",
      "env": { "PV_AI_SOCKET": "<socket>", "PV_AI_TOKEN": "<token>" }
    }
  }
}
```

Scripts use the same policy, audit and approval flow (set `PV_AI_SOCKET` and
`PV_AI_TOKEN` in the environment; never pass a real token as an argument):

```sh
/path/to/pv-mcp --call '{"op":"find","query":"server"}'
/path/to/pv-mcp --call '{"op":"read","id":"passwordvault:<id|slug|title>"}'
```

### Chat-redaction placeholders and the shell retry ticket

Some AI clients show the model placeholders such as `{{SECRET_x1y2z3a4}}` instead of real
values and only substitute the real value when a tool actually runs. `add` and `note_update`
refuse any value that still holds such a placeholder (`RedactedPlaceholderDetected`; known
category prefixes plus a generic `{{UPPER_lowercase-with-digit}}` shape, so ordinary
`{{name}}` / `{{API_TOKEN}}` templates pass). For a valid client the app also mints a
single-use ticket (in memory, 5 minutes, bound to the client and operation, cleared on lock;
the socket replies `{"error":"RedactedPlaceholderDetected","ticket":…}`). `pv-mcp` turns it
into a ready shell command:

```sh
PV_AI_SOCKET='<socket>' '/path/to/pv-mcp' --ticket <ticket> <<'PVJSON'
{ ...same arguments, placeholders verbatim... }
PVJSON
```

Shell tools resolve placeholders before running, and the arguments travel on stdin (never
argv). The retry needs no token and runs with the original client's policy, rate limit and
audit. If placeholders are still present it fails with `PlaceholderNotResolved` and no new
ticket is issued, so the AI stops instead of looping. Arguments are never echoed back in the
hint because some of them may already hold resolved values.

`tool/macos-nsh/package.sh` builds `pv-mcp` as a lightweight standalone workspace member
(`apps/desktop/helpers/pv-mcp`, embedding `apps/desktop/src/ai/tools.schema.json`),
places it at `Contents/MacOS/pv-mcp` in the signed preview bundle and signs it with the
app's identity. Both `pv-mcp` and `apps/desktop/ui/api/mcpTools.ts` read from the same
`tools.schema.json` file.

## Tools

Kept small so the model reads little: one-line descriptions, and the shared rules are sent
once as `initialize.instructions` (protocol 2024-11-05, or the client's 2025-03-26 /
2025-06-18). Successful calls return only the compact result JSON (nulls, empty strings and
empty lists are dropped); failures return one line `Code: hint`. Schemas reject extra
properties; the socket never exposes the control plane.

The MCP surface is five CRUD tools; `crud.rs` routes them onto the internal operations below.
Only the five public names are accepted (anything else is `ReadOnlyUnsupportedOperation`) and
audit rows record the public name. Any `id`, and a `find` query, may
be a reference `passwordvault:<id|slug|title>` (case-insensitive prefix, optional `//`):
exact ID, then note slug, then a unique exact title (`AmbiguousReference` otherwise).

| Tool | Routes to | Behavior |
| --- | --- | --- |
| `find` | `search`, or `note_list` for `kind:"note"`/note filters | Summaries `{id,type,title,sub}`; matches title, username, URL, tags, device host/aliases/services and app aliases |
| `read` | `get`, `get_secret` (`field`), `note_read` (Markdown notes/`slug`/`section`), `note_read_asset` (`attachmentId`), `note_history` (`history`/`revisionId`) | Ordinary fields plus `version`; secrets still need approval or a lease |
| `create` | `add`, or `note_update` with `createIfMissing` for `type:"note"` with `category`/`content` | No approval; shared 10 writes/minute per client |
| `update` | `entry_update`, `note_update` (`content`/`mode`/`slug`), `note_attach` (`attach{}`) | No approval. Entries: only supplied whitelisted fields change (custom fields merge by label), optional `version` lock (`VersionConflict`), the previous record is saved as an AI-attributed encrypted history revision and a replaced password is prepended to `passwordHistory`. Returns changed field names only |
| `delete` | `entry_delete` | Moves to the Trash (`isDeleted`, `deletedAt`) with a history revision; never purges |

Entries stay readable: instructions ask AI clients to put non-secret details in `note` as
`Label: value` lines and keep `customFields` for a few secrets. `create`/`update` enforce it
(`projection::split_fields`, limit 3): unlabeled or crowding non-secret fields are appended to
the note (`fieldsMovedToNote`), concealed fields always stay fields, `name`/`title` are accepted
as label aliases, and `update` accepts `removeFields` to tidy existing entries.

Writes refuse wallets/TOTP (no scope), excluded entries, and filed knowledge-base notes outside
`aiAccessNoteWritableCategories` (`NoteWriteDenied`). The former `ask_user` sheet was removed.

`create`, `update` and `delete` are the only tools that write data. They need no approval; every write is an AI-attributed history revision and `delete` only moves to the Trash.

Wallets, crypto records and TOTP secrets remain unavailable. Ordinary fields across accounts,
profiles, cards, devices (including service paths, notes and non-secret commands) and notes
are returned directly when their category scope is enabled and the entry is not excluded in
`aiAccessExcludedEntries`. Only passwords, card numbers, security codes, private keys,
tokens, concealed custom fields and secret device commands require approval (`read` with `field`).
Commands are returned only as data and never executed. Core still checks attachment
ownership and encrypted integrity.

### Delivery, leases and first-request grants

- `read` with `field` accepts `delivery: "clipboard"` (default) or `"reveal"`. Clipboard delivery
  writes the value to the general pasteboard marked `org.nspasteboard.ConcealedType` and
  `TransientType`, clears it after 30 seconds if nothing else was copied, and returns only
  `{delivered, clearsAfterSeconds, approval}` so the secret never enters the AI context.
  `reveal` returns `{value}`; the approval sheet warns that the client will see plaintext.
- The approver may allow once or start a lease for that client/entry/field: 15 minutes for
  any field, or until lock for phone/address/postal-code fields only. A reveal lease also
  covers clipboard requests, not the reverse. Leases live only in memory, are listed by
  `status` (`leases`), ended with control op `end_leases` (all, or `entryId`/`field`), and
  are cleared on lock, `configure`, `exclude` and `revoke`. Lease reads are audited as
  `AllowedByLease`.
- `get` on an existing, non-deleted, non-excluded entry in an enabled category returns
  ordinary fields directly. Disabled scopes, excluded entries, unknown/deleted entries,
  wallets and unauthorized file reads fail closed without asking.
- `purpose` is untrusted client text, truncated to 120 characters before display.

Approval expires after 60 seconds. Closing the sheet denies it. Any scope/exclusion
change cancels pending approvals. The app rechecks live lock state, client token,
entry permission and a hash of the complete entry after approval; a changed entry
requires a new request. Consumed approvals cannot be replayed.

## Encrypted persistence and audit

Only the core `settings` operation writes configuration:
`aiAccessEnabled`, `aiAccessScopes` (`accounts`, `profiles`, `devices`, `notes`, `noteAssets`),
`aiAccessClients` (token SHA-256 digest and name), `aiAccessExcludedEntries`,
`aiAccessNoteAutoWrite`, `aiAccessNoteWritableCategories`, `aiAccessNoteAssetText`,
`aiAccessAliases`, `aiAccessOrdinaryFiles`, `aiAccessAudit`. Missing settings mean
OFF/deny. No plaintext settings file exists. The UI strips token digests from its status response.

Audit is bounded to 200 entries and records trusted client ID, known item ID,
canonical operation, result, generated request ID and Unix time; never returned
content, query text, credentials or arbitrary unknown operation text. Output is
withheld if the encrypted audit write fails. Requests while locked are denied and
held as bounded content-free audit metadata in memory, flushed after unlock;
these pending records are lost on app exit. An unknown/locked client is identified
as `unknown`, because credentials cannot be validated without the encrypted settings.

## Exact UI wiring

- Settings: `import { AiPage } from "./ai"`; set `PAGES.ai = AiPage`.
- App: `import { AiApprovalHost } from "./ui/ai"`; mount `<AiApprovalHost />`
  exactly once alongside other overlay hosts, outside the Settings visibility
  conditional. It starts the socket with `vaultInstance` after unlock and polls
  pending requests. It cancels approvals immediately when UI phase becomes locked.
- Device AI tab: `<AiEntryPage id={item.id} />`, imported from `ui/ai`.
  It edits aliases and renders explicit file-classification switches.
- Note attachment metadata, if desired: `<AiFileAccess entryId={item.id}
  fileId={attachment.id} name={attachment.name} />`. Classification is an explicit
  content decision, never inferred from `.txt`, `.command`, or MIME type.
- The settings client entry rows offer real policy-backed trial queries. The secret
  trial displays only approval outcome, never the returned value in the UI.

## Validation and remaining acceptance

Run from the repository root against a fresh copy of `/tmp/pv-nsh-qa/vault`:

```sh
PASSWORDVAULT_VAULT_DIRECTORY='<fresh synthetic vault copy>' bash tool/nsh_mac.sh check
PASSWORDVAULT_VAULT_DIRECTORY='<fresh synthetic vault copy>' bash tool/nsh_mac.sh test --filter ai::tests
```

Tests cover default-off, unscoped entries, revoked tokens, wallet denial, locked
core, secret stripping, private device fields, service-path and private-command release,
compact summaries/details, ordinary classification, approval deadline/denial, real
encrypted pairing, single-use approvals, revocation during approval,
UTF-8 file chunking, unclassified-file and wrong-owner rejection, and
content-free audit.
Native approval-sheet appearance, real AI clients, a full signed-package run,
peer-credential rejection across OS users and full device attachment round trips
still require integration acceptance. This preview is not production-security acceptance.

Socket responses contain `{ok, result|error, requestId}`; the server-generated UUID
is shared by the approval sheet and the encrypted audit record.
