# Install PasswordVault 2.4.0

Download all assets before checking `shasum -a 256 -c SHA256SUMS`. `BUILD.json`
identifies the reviewed commit and versions. These are developer previews with
remaining security and hardware validation work, not audited production releases.

## Mac

The current NSH package is Apple Silicon / macOS 14+. Extract PasswordVault.app
and place it in Applications. The legacy SwiftUI client is retained as source only in this release; no new Intel
Mac package is published. Do not run both clients against one vault simultaneously.
Keep a verified complete encrypted backup before switching implementations.
The NSH package uses the existing PasswordVaultNative data directory;
new formats may require restoration of the pre-upgrade backup to use an older app.

Public packages are ad-hoc signed and not notarized. macOS or managed-device policy
may prevent launch. Touch ID enrollment is not promised; ensure master-password
access before replacing a locally provisioned build. Local builds with eligible
Apple signing credentials can retain their provisioning. Browser grants may need
reauthorization when helper signing changes.

## Android

Choose the APK matching the device architecture. Android 8.0+ is required. Public
APKs use the reviewed signing certificate in SIGNING-CERTIFICATE-SHA256.txt and the
native-preview package identity. A differently signed local/debug application
cannot be overwritten with this APK. Preserve and verify an encrypted backup;
never remove the only vault copy to work around a signature error.

## Browser and Web

Extract the extension to a permanent folder, enable Developer mode in Chrome/Edge,
and load the directory containing manifest.json. Reload after upgrades and confirm
version 2.4.0. Register the browser in Mac settings before using the native bridge.
Independent browser/Web vaults are separate and do not automatically merge data.
Serve the Web download over HTTPS or loopback HTTP; do not use file URLs.

## iOS

The simulator archive requires a compatible Xcode simulator on Mac. It is not an
IPA and cannot be installed on an iPhone. Device provisioning, AutoFill/App Group
eligibility and signed device distribution remain separate requirements.

## Data and permissions

Device-group membership alone does not grant vault access. Grant only intended
peers and AI clients the required scope. Revocation stops future exchanges but
cannot erase previously downloaded copies. Explicit plaintext exports are plaintext.
The local security model still has unresolved acceptance gates. Test with synthetic
data before relying on unverified workflows.
