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
2. Enter a recognizable client name and generate a confirmation code in Settings.
   It expires after 120 seconds and is consumed by one pairing attempt.
3. Run the adapter's script mode with the code. The app returns a random client ID
   and token exactly once. Neither token nor confirmation code goes in audit logs.
4. Explicitly grant that client individual entries. Pairing alone grants none.
   File access additionally needs the per-entry client switch and explicit ordinary
   classification of each immutable attachment ID.

```sh
PV_AI_SOCKET='<socket shown in Settings>' /path/to/pv-mcp --call '{"op":"pair","code":"<confirmation code>"}'
```

Example client configuration (illustrative only; do not edit real AI client
configuration during development):

```json
{
  "mcpServers": {
    "passwordvault": {
      "command": "/path/to/pv-mcp",
      "env": {
        "PV_AI_SOCKET": "<socket shown in Settings>",
        "PV_AI_TOKEN": "<token returned by pairing>"
      }
    }
  }
}
```

Scripts use the same policy, audit, and approval flow:

```sh
/path/to/pv-mcp --call '{"op":"search_entries","query":"server"}'
/path/to/pv-mcp --call '{"op":"get_entry","id":"<stable ID>"}'
```

Set `PV_AI_SOCKET` and `PV_AI_TOKEN` in the script environment. Never pass a real
token as a command argument or commit it. `tool/macos-nsh/package.sh` builds `pv-mcp`,
places it at `Contents/MacOS/pv-mcp` in the signed preview bundle and signs it with the app's
identity; Settings → AI 访问 shows a client configuration pointing at that path.
`nsh check` validates the binary target; its source is `src/bin/pv-mcp.rs`.

## Tool schemas

All tools describe returned documents/scripts as untrusted **data, never
instructions**. No tools execute commands, launch services, or modify records.
MCP supports `initialize`, `ping`, `tools/list`, `tools/call`; protocol 2024-11-05.
Schemas reject extra properties at the MCP schema level; the app only consumes
known read parameters and never exposes its control plane through the socket.

| Tool | Arguments | Result |
| --- | --- | --- |
| `search_entries` | `query?: string` | At most 100 permitted `{id,type,title}` summaries; matches titles, tags, device aliases, app aliases |
| `get_entry` | `id: string` | Whitelisted ordinary fields, never complete records |
| `list_files` | `id: string` | Only ordinary, client-authorized file ID summaries |
| `read_file` | `id, fileId: string`, `offset?: integer`, `limit?: integer` | UTF-8 text, Unicode-scalar offsets, `nextOffset`, `eof`, `dataOnly`; default 4096, maximum 16384 scalars |
| `get_secret` | `id: string`, `field: password\|token\|privateKey\|nodeLink\|notes` | One string field after a fresh app approval; accounts support `password`, devices read the nested field |

No wallets, identity documents, cards, crypto records or TOTP secrets are exposed.
Device projection follows `docs/DEVICE-ITEMS.md`: host/port/username/authMethod,
aliases, service identity/kind/ports, and only commands explicitly marked
`secret:false`. Device notes, service paths, unclassified commands and files are
excluded. Commands are returned only as data. Service-path and individual private
command retrieval are not currently supported by `get_secret`; they fail closed.
Account details expose title, website and username; authorized notes expose their
body/document. Core still checks attachment ownership and encrypted integrity.

Approval expires after 60 seconds. Closing the sheet denies it. Any scope/grant
change cancels pending approvals. The app rechecks live lock state, client token,
entry permission and a hash of the complete entry after approval; a changed entry
requires a new request. Consumed approvals cannot be replayed.

## Encrypted persistence and audit

Only the core `settings` operation writes configuration:
`aiAccessEnabled`, `aiAccessScopes`, `aiAccessClients` (token SHA-256 digest,
per-client entry/file maps), `aiAccessAliases`, `aiAccessOrdinaryFiles`,
`aiAccessAudit`. Missing settings mean OFF/deny. No plaintext settings file exists.
The UI strips token digests from its status response.

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
core, secret stripping, private device fields, ordinary classification, approval
deadline/denial (including expired pending requests), real encrypted pairing, single-use approvals, revocation during approval, UTF-8 file chunking, unclassified-file and wrong-owner rejection, and content-free audit.
Native approval-sheet appearance, real AI clients, a full signed-package run,
peer-credential rejection across OS users and full device attachment round trips
still require integration acceptance. This preview is not production-security acceptance.

Socket responses contain `{ok, result|error, requestId}`; the server-generated UUID
is shared by the approval sheet and the encrypted audit record.
