# Account and authenticator screens

`AccountDetail` and `CodeDetail` take `{ item: Item; editing: boolean }`. They reuse
store edits (including the existing coalesced password history), the shared field
kit, and core TOTP/passkey operations. `askAddCode()` validates imports before
creating an item; it optionally accepts an apply callback for existing records.

## Integration (owned by the shell editor)

In `ui/Detail.tsx`, import:

```tsx
import { AccountDetail } from "./entries/AccountDetail";
import { CodeDetail } from "./entries/CodeDetail";
```

Remove the old local `AccountDetail` and `CodeDetail` definitions. Keep `NoteBlock`
and `Meta`, since wallet details still use them. Remove `CodeField` if unused.
Replace the two branches of `ItemView` with:

```tsx
<AccountDetail item={props.item} editing={editing() && !props.item.isDeleted} />
<CodeDetail item={props.item} editing={editing() && !props.item.isDeleted} />
```

In `ui/ItemList.tsx`, import `askAddCode` from `./entries/CodeDetail`. Change the
`newItemMenu()` authenticator action to `onSelect: () => askAddCode()` and add
`if (dest() === "codes") return askAddCode();` near the start of `newInCurrent()`.
Do not create a blank authenticator before showing the sheet. Route any other
keyboard/menu authenticator creation entry points through the same function.

`src/qr_import.rs` is registered as `QrImport` in the existing native registry.
Image bytes remain in Rust. PNG/JPEG/GIF/WebP are supported, with a 20 MB file
limit and bounded decoded dimensions/allocation. An image must contain exactly
one distinct otpauth URI; the core then validates algorithm, digits and secret.
Camera and live screen scanning are outside this implementation.

## Verification

Use a new copy of `/tmp/pv-nsh-qa/vault` for each command, assigned through
`PASSWORDVAULT_VAULT_DIRECTORY`:

- `bash tool/nsh_mac.sh check`
- `bash tool/nsh_mac.sh test tests/entries.test.tsx`
- `bash tool/nsh_mac.sh test --filter qr_import -v`

The headless tests cover account edits/removal, URI import, next-code rendering,
clipboard setup URI, persisted color, and rejected imports. Rust generates and
decodes a QR fixture and rejects non-authenticator QR and malformed images.
Native file-panel interaction, actual browser launches, GUI layout and camera
behavior have not been accepted by these tests.
