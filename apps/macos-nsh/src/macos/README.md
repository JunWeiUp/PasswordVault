# Preview native services

The preview uses `com.securepass.vault.nshpreview.biometric`, with a SHA-256
account derived from the canonical vault base directory. It never queries the
SwiftUI app's service. Moving a vault requires enrollment again.

Enrollment requires an unlocked session and master-password reauthentication
through `vault_core::Header::unlock`. The resulting root must match the live
session. Keychain uses the data protection keychain,
`WhenUnlockedThisDeviceOnly`, `biometryCurrentSet`, and no synchronization.
Duplicate enrollment updates both data and access control, propagating failure.
Retrieval uses a fresh LAContext with zero authentication reuse. Key bytes stay
in Rust; owned Rust buffers are zeroized. Disabling removes only the matching
preview service/account item. An invalidated or missing item requires master
password unlock and re-enrollment. Changing the master password or restoring a
vault should disable/re-enroll the credential as part of that UI workflow.

## UI integration

In `ui/store.ts`, import `bindNativeVault` from `./native` and call it immediately
after constructing the store's single Vault instance. Do not construct another
Vault for biometric operations. Boot's status command initializes the session
before biometric unlock is offered.

Settings should query `biometricAvailability()` and `biometricEnabled()`, request
the current master password in a masked field, await `enableBiometrics(password)`
or `disableBiometrics()`, then re-query enabled state. Clear the password field
in a finally block and display `biometricError(error)` on failure. Do not use a
plaintext preference as evidence of successful Keychain enrollment.

Subscribe once with `onLockSignals(listener)` at App lifetime and call its returned
stop function at teardown. It drains notification bits every 500 ms: sleep=1,
session resign=2, screen lock=4, screensaver=8. Continue draining while the vault
is locked. Sleep applies unless `macLockOnSleep === false`; bits 2/4/8 apply
unless `macLockOnScreenLock === false`. Only explicit false disables these
policies. Idle seconds come from the combined-session CoreGraphics event source;
null means unavailable. Idle locking respects `macNeverIdleLock` independently.
Background refreshes must not reset the system idle timeout.

Notifications only enqueue signals: the JS subscriber applies policy and locks.
Delivery can be delayed while JS is blocked or the machine is asleep; this is
not a pre-sleep lock guarantee. Ensure the app's lock path persists pending edits
and clears decrypted state. Serialize lock/unlock actions and guard pending
biometric completion against intervening lock/teardown actions.

## Validation and signing

`bash tool/nsh_mac.sh check` builds bridge declarations and checks TSX.
`bash tool/nsh_mac.sh test` runs Rust tests and headless TSX tests; use a fresh
synthetic seeded vault copy in `PASSWORDVAULT_VAULT_DIRECTORY`. Rust tests use
their own temporary synthetic vault and an isolated notification center. They
never enroll or delete any Keychain item.

Real Touch ID needs a separately identified preview app bundle, an Apple
Development or Developer ID signature appropriate to the distribution route,
and matching application identifier / Keychain access group entitlements (plus
a provisioning profile where required). Keep the preview service and account
namespace unchanged and distinct from production; do not reuse production
Keychain items. Configure signing locally without committing private material.
Verify the final bundle signature and embedded entitlements, then install/run
outside Documents. Ad-hoc builds may fail with `-34018`.

Hardware acceptance remains separate: enroll, cancel, successful unlock,
incorrect password, disable, stale fingerprint set, lockout, sleep/wake,
screen lock and user switching. No real Keychain or physical sleep acceptance
is implied by compilation or synthetic notification tests.
