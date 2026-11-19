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
   tokens, concealed custom fields and secret device commands go through `get_secret`
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
/path/to/pv-mcp --call '{"op":"search","query":"server"}'
/path/to/pv-mcp --call '{"op":"get","id":"<stable ID>"}'
```

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

| Tool | Arguments | Result |
| --- | --- | --- |
| `search` | `query?` | At most 100 `{id,type,title,sub}` across enabled categories (excluding `aiAccessExcludedEntries`); `sub` is username, host, email or card brand. Matches title, tags, device aliases, host, service names and app aliases |
| `get` | `id`, `fileId?`, `offset?`, `limit?` | Without `fileId`: ordinary plain-text fields (account username/url/note, identity contact/address fields, card brand/holder/expiry, device host/port/username/services/paths/notes/non-secret commands, non-hidden note text), non-concealed custom `fields`, `secretFields` (names requiring `get_secret`) and `files` (ordinary file IDs). With `fileId`: UTF-8 `{text,nextOffset,eof}`, default 4096, maximum 16384 scalars |
| `get_secret` | `id`, `field`, `delivery?: clipboard\|reveal`, `purpose?` | One high-sensitivity secret after approval or an active lease: `password`, `token`, `privateKey`, `nodeLink`, `number`, `securityCode`, `custom:<id>` (concealed), and `command:<id>` (secret device command) |
| `note_list` | `category?`, `tag?`, `query?`, `propertyKey?`, `propertyValue?`, `limit?` | Lists non-hidden notes matching filters along with `slug`, `category`, `tags`, `properties`, `writable`, and the configured `writableCategories` |
| `note_read` | `id` or `slug`, `section?` | Returns canonical Markdown, `properties`, `tags`, `attachments[]` (including `aiTextAllowed`), `versionHash`, and `writable` |
| `note_update` | `id` or `slug`, `mode: append\|replace_section\|replace`, `content`, `summary`, `section?`, `expectedVersion?`, `createIfMissing?`, `category?`, `title?`, `properties?`, `tags?` | No-popup auto-save into whitelisted `aiAccessNoteWritableCategories` (30/min rate limit, mandatory `summary`, optimistic lock `VersionConflict`, immutable encrypted history revision). Never modifies credentials or deletes notes |
| `note_attach` | `id` or `slug`, `path`, `name?`, `summary`, `insertLink?`, `aiTextAllowed?` | Encrypts a local file (≤ 100 MiB) into chunked `<vault_dir>/blobs/<id>.pvblob`, appends `[name](pv-asset://<id>)` to a whitelisted note, records history, and leaves the original file untouched |
| `note_read_asset` | `id` or `slug`, `attachmentId`, `offset?`, `limit?` | Returns bounded locally extracted plain text (PDFKit / DOCX / XLSX / PPTX / UTF-8, no network) only when `noteAssets` scope and the attachment's `AI 可读文本` toggle are both enabled |
| `note_history` | `id` or `slug`, `revisionId?`, `limit?` | Lists encrypted note history revisions or returns a specific historical revision snapshot |
| `add` | `type: account\|note\|totp\|identity\|card\|device`, `title`, plus type fields (`username`, `password`, `url`, `note`, `tags`, `secret`/`issuer`/`period`, `identity{}`, `card{}`, `device{}`) | Saves a new entry immediately, **without approval or scope**: only a valid paired client and an unlocked vault are required. Fields are whitelisted and bounded; a fresh ID is always generated so existing records cannot be overwritten. Device commands are private unless `secret:false`; devices need the vault's 设备与服务 upgrade (`DevicesNotEnabled`). Wallets are refused. Each client may add at most 10 entries per rolling minute (`RateLimited`; in memory, failed saves do not count). Audited as `add` (no content), and the window reloads its list. Returns `{id,type,title,added}` |
| `ask_user` | `title`, `url?`, `username?`, `delivery?`, `purpose?` | When no account exists: the user fills a sheet (AI values are only suggestions), the UI saves a new account through the normal store path and returns it with the password delivered like `get_secret`. Cancel returns `ApprovalDenied` |

`add`, `ask_user`, `note_update` (whitelisted note categories only) and `note_attach` (whitelisted note categories only) are the only tools that write data; nothing edits credentials or deletes records. `ask_user` needs the `accounts` scope. Its sheet expires after 180 seconds.

Wallets, crypto records and TOTP secrets remain unavailable. Ordinary fields across accounts,
profiles, cards, devices (including service paths, notes and non-secret commands) and notes
are returned directly when their category scope is enabled and the entry is not excluded in
`aiAccessExcludedEntries`. Only passwords, card numbers, security codes, private keys,
tokens, concealed custom fields and secret device commands require `get_secret` approval.
Commands are returned only as data and never executed. Core still checks attachment
ownership and encrypted integrity.

### Delivery, leases and first-request grants

- `get_secret` accepts `delivery: "clipboard"` (default) or `"reveal"`. Clipboard delivery
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
encrypted pairing, single-use approvals, revocation during approval, `ask_user`
cancel/save/grant, UTF-8 file chunking, unclassified-file and wrong-owner rejection, and
content-free audit.
Native approval-sheet appearance, real AI clients, a full signed-package run,
peer-credential rejection across OS users and full device attachment round trips
still require integration acceptance. This preview is not production-security acceptance.

Socket responses contain `{ok, result|error, requestId}`; the server-generated UUID
is shared by the approval sheet and the encrypted audit record.
