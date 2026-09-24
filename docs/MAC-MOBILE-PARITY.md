# Mac direct-entry and rendered-note acceptance

Mac preview **2.0.7, build 11** aligns record details with native Android 2.1.5. New creates a saved blank entry and selects it immediately. The title and detail edit in place; writes use the existing encrypted autosave/retry path. There is no separate creation or editing form sheet. Delete moves unwanted entries to Trash.

| Area | Mac detail coverage |
| --- | --- |
| Account / authenticator | Username, password, independent reveal/copy/generation, change time and history, stable additional accounts with purpose/username/password and independent history |
| Linked verification | Secret, interval, live code, setup-link import/copy, QR/image import, confirmed clearing; new imports use their parsed name |
| Other credential fields | Email, multiple websites/domains, per-site opening, password duration and multiline notes |
| Wallet | Full address, custom/default/existing network, hidden private key, explicit private-key derivation, complete numbered recovery phrase, paste/copy, 12/24-word editing and BIP39 suggestions; confirmed replacement generation |
| Common metadata | Default/existing/custom category, writable shared vault, tags, pin, favorite and color |
| Access / lifecycle | Viewer/Trash remain read-only; existing unknown fields survive edits; pending generation results expire on navigation and newer work |

## Notes

The main note surface renders headings, emphasis, inline links, lists, checkboxes, quotes and fenced code while preserving Markdown source in encrypted storage. Syntax markers are absent from the rendered body and list snippet. Edit and Preview share typography; clicking an editable preview places the caret and enters Edit without a modal or paragraph panel. A secondary Markdown source action remains available. Plain-format legacy notes remain literal.

Selection uses UTF-16 source ranges rather than invisible editable syntax. Undo/redo stores source snapshots, not AppKit presentation edits. Active input-method composition retains provisional source mapping and formats after commit. Full-document replacement clears hidden delimiters; typing after a closed fence starts outside it. The renderer is not a complete CommonMark/GFM engine: complex tables, reference definitions and deeply nested block structures remain outside this acceptance matrix.

## Evidence

- 46 Swift tests pass, including immediate create/lock/reopen for all four types; original and additional password histories; password reversion; external credential refresh; legacy account-ID normalization; rendered Markdown editing, Unicode, cross-paragraph selection, full deletion/replacement, fence-end input and Chinese composition with undo/redo.
- `bash tool/check_native.sh macos` passes the universal native build. The Personal Team signing identity and existing application/vault identifiers are retained.
- An isolated synthetic-vault UI run confirmed immediate new note/account/code/wallet, account and additional-account filling, TOTP-link name/username import, wallet generation with secrets concealed, `# d` rendered as a heading, preview click-to-edit, Return, undo/redo, fence-end input, whole-document replacement and lock/reopen persistence.
- Interaction-designer review: **9.1/10** for this increment after fixing history, identity, stale-result and Markdown mapping findings. This score is limited to the reviewed code, independent native-text reproductions and the synthetic UI flow above.
- The signed 2.0.7 build 11 was installed at the existing local app location and reopened to the locked screen with its Touch ID entry available; hardware fingerprint acceptance was not repeated.
- Automated composition uses native NSTextView marked-text APIs; this does not claim hardware/input-source matrix acceptance. Camera hardware, every QR image format, all third-party Markdown dialects and all display/language settings were not reaccepted in this increment. No real vault was used for testing.

Encrypted storage, migration formats and browser extension code are unchanged. This preview does not close the independent blockers in [the security model](SECURITY_MODEL.md).
