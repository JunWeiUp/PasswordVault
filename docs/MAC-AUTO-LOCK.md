# Mac automatic locking

In **Settings → Security → Automatic locking**, screen-lock and sleep behavior can each be set to **Lock immediately** or **Don't lock**. Both default to immediate locking, including when an older or imported vault has no preference. Malformed preference values also keep immediate locking.

- **When the screen locks** also covers switching away from the current macOS user session.
- **When the Mac sleeps** controls the sleep event. If sleep also triggers a screen lock, the screen-lock preference applies independently. Select Don't lock for both to retain an unlocked vault through both events.
- **Lock when idle** remains independent. Time spent locked at the system level or asleep can still reach the configured idle timeout. Choose Never separately if no idle locking is wanted.
- Manual locking and application quit still lock the vault. These options never unlock a vault automatically.

The preferences are Boolean `macLockOnScreenLock` and `macLockOnSleep` values in the existing encrypted vault settings, not plaintext preferences. Only an explicit Boolean `false` disables an event. They do not change mobile locking policy, encryption, key wrapping or vault formats. Data at rest remains encrypted while unlocked; decrypted content remains available in the running process until the vault locks.

## Validation

`SystemLockTests` uses UUID-named synthetic vaults and isolated notification centers. It covers missing/malformed settings, all four policy combinations, screen/sleep/session notifications, consecutive sleep and screen-lock events, encrypted settings persistence, failed-save rollback, independent manual/idle locks, and preservation of the latest unsaved note on immediate locking.

The six system-lock tests and eleven existing interaction tests passed together on the development Mac. The scoped run does not replace physical lock/sleep acceptance.

Mac **2.0.10 build 14** was built with the existing local Apple Development identity and installed over the previous development app. Signature and Keychain access-group continuity were checked; the running Security settings showed both new pickers with their default Lock immediately value. The vault location was preserved. This is a local development installation, not a public notarized release.

Physical sleep/wake, lock-screen timing and switching macOS users require separate hardware acceptance. Posting synthetic notifications verifies application handling without sleeping or locking the developer's actual computer.

## Current local installation

Mac **2.2.1 build 17** integrates these settings with the coordinated 2.2.1 source. The arm64/x86_64 application was rebuilt with a renewed local Apple Development profile and installed in the standard Applications folder. Bundle identity and Keychain access groups remain unchanged. Existing browser host registrations point to the installed helper; the former development-app path redirects to this installation.

Nineteen system-lock, interaction and biometric error-handling tests passed against synthetic vaults. Strict signature verification, provisioning validity, application launch and the installed helper's locked status response passed. Existing vault contents were not used as test data. Fresh physical Touch ID, sleep/wake and Intel acceptance were not repeated. This remains a personal development build, separate from the public 2.2.1 archive.
