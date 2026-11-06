# Legacy Mac client — SwiftUI

**This directory is the legacy Mac implementation.** Current Mac development and
the owner's daily installation use [`../macos-nsh`](../macos-nsh/README.md)
(Native Shell 0.4.0 and the official native RichEditor).

Retain this client for rollback, legacy compatibility and manual compatibility checks; it has no automated CI or release artifact. It supports macOS 13+ and universal Apple Silicon/Intel builds;
the NSH client currently targets macOS 14+ / Apple Silicon. This is not a claim
that either client has passed production security acceptance.

- Build: `bash tool/check_native.sh macos` from the repository root.
- Tests: `bash tool/test_macos_isolated.sh`; never test with a real vault.
- Shared web editor: [`../shared/note-editor`](../shared/note-editor/README.md).
- Some Swift files/resources are referenced by iOS and NSH packaging. Keep this
  directory path stable until those dependencies are deliberately migrated.
- Do not change bundle IDs, Keychain groups or vault directories when labeling
  or maintaining this legacy client.

The legacy standalone CI job is disabled at the owner's request. Current releases
ship NSH Mac only. iOS still verifies the specific Swift sources it shares here.
