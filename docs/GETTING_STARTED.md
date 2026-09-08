# Getting started with PasswordVault

PasswordVault is a developer preview. Use fictional accounts and disposable secrets while evaluating it. The [security model](SECURITY_MODEL.md) explains unresolved issues with master-password storage, password changes, backup derivation, and sharing.

[English overview](../README.md) · [中文介绍](../README.zh-CN.md) · [Build from source](../README.md#run-from-source)

## Choose a build

The [existing preview release](https://github.com/JunWeiUp/PasswordVault/releases/tag/v1.1.0-preview.4) provides Android packages, a Chromium extension ZIP, a Web ZIP, and checksums. This release includes the redesigned workspace shown in the README. You can also [run the current source](../README.md#run-from-source) or use a CI artifact built from a later revision.

| You want to try | Choose | Requirements |
| --- | --- | --- |
| Android app | An `.apk` for your device architecture | Android 7.0+; recent phones usually use `arm64-v8a` |
| Chrome or Edge extension | The `chrome-extension` ZIP | A Chromium browser with developer mode enabled |
| Browser app | The `web` ZIP or a source run | A local HTTP server or your own hosting |
| Native iOS app | The source project | macOS, Xcode, signing, and additional device validation |

The AAB is for Android distribution tooling; it is not directly installable like an APK. No native Windows, macOS, or Linux runner is included. A wide README screenshot represents responsive Flutter UI only.

### Android

1. Download the APK matching your device from the preview release.
2. Compare its SHA-256 hash with the release's `SHA256SUMS` before installing. On macOS use `shasum -a 256 <filename.apk>`; on Linux use `sha256sum <filename.apk>`; on Windows use `Get-FileHash <filename.apk> -Algorithm SHA256` in PowerShell.
3. Open the APK and, if Android asks, allow installation from the source you chose. Launch PasswordVault after installation.

For a local development APK, use `bash tool/check.sh android`. Its output is `build/app/outputs/flutter-apk/app-debug.apk`. Debug and release signing identities differ; do not assume one can update the other. If an update fails, preserve existing data before considering any reinstall.

The presence of an autofill service or biometric setting does not verify it on your device. Those behaviors require platform testing; the README images do not provide that evidence.

### Chrome / Edge extension

1. Extract the extension ZIP to a folder you intend to keep. For a source build, run `bash tool/check.sh web` and use `build/chrome_extension`.
2. Open `chrome://extensions` or `edge://extensions`, enable **Developer mode**, choose **Load unpacked**, and select the folder containing `manifest.json`.
3. Open the PasswordVault extension and create a test vault. Evaluate autofill only on a page and account you control.

Keep the unpacked directory and extension identity stable. Removing an extension, changing its identity, or deleting its browser profile can lose access to its stored data. Rehearse backup and restore before changing installations. The extension is experimental; read its [storage and message-boundary limitations](SECURITY_MODEL.md).

### Web

For development, follow the [source setup](../README.md#run-from-source) and run `flutter run -d chrome`.

For a built Web ZIP, extract it into an empty directory and serve that directory over HTTP. For example, run `python3 -m http.server 8080` from the extracted directory, then open `http://localhost:8080`. Opening `index.html` with a `file://` URL is not the supported path. For remote hosting, configure your own HTTPS origin and the required server headers.

Browser storage currently persists the master password. Do not use this build for real credentials. WebDAV requests are also subject to browser CORS rules, and ordinary browsers cannot host the local sync server. See [Development](DEVELOPMENT.md#build).

## Your first session

### 1. Create a disposable vault

Choose a master password used only for this preview, then confirm it. The lock screen offers language selection, password visibility controls, and inline errors. If setup fails, correct the input or retry from the form.

The redesigned workspace starts in **Accounts**. Its navigation order is **Accounts → Codes → Wallets → Notes → Settings**. Compact screens use a bottom bar; widths of 840 logical pixels or more use a sidebar.

### 2. Add one fictional account

Use the add action in Accounts to create a sample entry, such as a service named `Example account` with username `hello@example.com` and a disposable password. Save it, then try:

- Search by title, username, or domain. With a keyboard, **⌘K** on macOS or **Ctrl+K** on other platforms focuses search.
- Use a category, tag, favorite, or sort option to change what you see.
- Clear a query with the search field's clear action. If the combination of filters has no matches, the empty state offers a way to clear them.
- Switch content views, then return to your list. The workspace retains mounted views and list scroll positions during the session.

Use the entry's copy action to copy a sample credential. Test in a disposable text field; never paste a credential into an issue or chat.

### 3. Try a supporting tool

Open the password generator from the top bar, the wide sidebar, or **Settings → Tools**. Choose a length from 4 to 64 characters and the character types you need. Select at least one type to generate or copy a password. Copy the result or regenerate; the extension also supports filling the current page.

Password health checks are available from Settings and the wide sidebar. They flag weak, reused, or expired passwords; a clean report is not an assessment of the app's overall security.

### 4. Rehearse recovery

From **Settings → Data management**, open **Import and export**. Export synthetic entries, then use a separate test installation or browser profile to check that an import returns the expected sample data. Do not reset your existing vault to test recovery.

For WebDAV, open **Settings → Data management → WebDAV backup**, configure your test server, and check that a backup can be restored in a separate test environment. Encrypted backups still have [legacy derivation limitations](SECURITY_MODEL.md); unencrypted exports may contain plaintext secrets.

Do not change the master password of a vault you rely on: transactional re-encryption is an unresolved release blocker. Do not treat a backup file's existence as proof that it can be restored.

## Troubleshooting

| What you see | What to check |
| --- | --- |
| No search results | Clear the query and active category, tag, favorite, or shared-vault filters |
| Extension will not load | Select the extracted folder containing `manifest.json`, not the ZIP or its parent directory |
| APK will not update an existing app | Confirm matching app/signing identity and an appropriate version; preserve data before reinstalling |
| Web build is blank or cannot load SQLite | Serve it over HTTP, keep the packaged WASM/worker files together, and inspect the browser console |
| WebDAV works natively but fails in the browser | Check the server's CORS policy for your Web origin and required methods |
| Generator cannot copy | Select at least one character type; retry if the platform clipboard reports an error |
| Autofill, biometrics, or sharing fails | Record the platform, build revision, and reproduction steps; these require runtime validation |
| Flutter check rejects the SDK | Install the version pinned in `.flutter-version`; inspect `flutter doctor -v` |

For a bug report, include the source revision or release tag, operating system, browser/device details, steps to reproduce, and screenshots made with fictional data. Use the [issue templates](https://github.com/JunWeiUp/PasswordVault/issues/new/choose). Report vulnerabilities through [SECURITY.md](../SECURITY.md).

## Where next

- [Product design](PRODUCT_DESIGN.md): navigation, interactions, and visual standards.
- [Development](DEVELOPMENT.md): architecture, toolchain, and validation commands.
- [Releasing](RELEASING.md): CI artifacts, private signing, package verification, and public preview releases.
- [Security model](SECURITY_MODEL.md) and [privacy policy](../PRIVACY.md): current limitations and data flows.
