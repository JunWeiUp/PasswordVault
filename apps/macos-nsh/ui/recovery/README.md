# Recovery and entry history

`RecoverySettings` belongs in Settings → Backup & Import. `askRecoveryReset()`
opens the locked-vault password reset sheet; `askEmergencyRestore()` opens the
first-run archive recovery sheet. `openItemHistory(item)` from `../history` belongs
in the detail menu.

Recovery setup shows a newly generated key once, verifies its third group and
requires the outside-vault acknowledgement plus the current master password.
Component disposal and locking clear transient secrets. Copy is cleared on sheet
exit if the clipboard still contains the copied key. Printing uses the system
print panel without a plaintext temporary file. Printed/PDF copies remain under
the user's control.

`RecoveryIO` keeps archive content in Rust. Export creates a new file with mode
0600 and refuses replacement (choose another filename even if the system panel
allows replacing a file). Restore bounds reads to 1 GiB and delegates authentication
and the nonexistent-target check to vault-core. Reset checks for a locked session.
Neither replacing nor disabling a recovery key invalidates existing archives.

History initially displays timestamps and differing field names. Personal core
revisions do not contain device metadata, so the UI says “device not recorded”.
Secret snapshots require explicit reveal; selection changes reset reveal. Restore
flushes edits and creates a new version; pruning requires confirmation and explains
personal versus peer history retention.

Headless coverage: `tests/recovery.test.tsx`, `tests/history.test.tsx`; native IO
coverage is in `src/recovery_io.rs`. Use the repository's `tool/nsh_mac.sh` with a
fresh synthetic vault. Native save/open panels, physical printing and accessibility
on a real window still require manual acceptance. No real vault is used by tests.
