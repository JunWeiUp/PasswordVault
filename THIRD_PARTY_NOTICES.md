# Third-party notices

PasswordVault is MIT licensed. Dependencies, Flutter engine assets, SQLite, icons, and generated runtime bundles retain their respective licenses.

The authoritative dependency versions are in `pubspec.lock`. Review their package license files before distributing binaries. Flutter includes an asset license registry in built applications (`NOTICES` / `NOTICES.Z`); retain it in web and extension packages. The app's About section links to Flutter's license viewer.

Notable components include Flutter (BSD-3-Clause), Drift (MIT), sqlite3.dart (MIT), SQLite (public domain), and cryptography (Apache-2.0). This list is descriptive and not a replacement for the complete bundled notices.

The extension package includes locally bundled Flutter/CanvasKit and Drift runtime assets. Do not remove their notices during packaging.

Documentation renders use Roboto and Material Icons from the pinned Flutter SDK. The capture harness also includes Roboto Mono by the Roboto Mono Project Authors, distributed under the SIL Open Font License 1.1; see [the included license](docs/images/fonts/OFL.txt). This font is used only by the screenshot harness and is not registered as an application asset.
