# Windows desktop development

The Windows client shares `apps/desktop` with macOS. Use Windows x64 tools;
on Windows 11 ARM these run through Windows' x64 emulation. The portable package is included in regular releases from 2.4.1; it is unsigned. It is not a security acceptance claim.
Users also need the Microsoft Visual C++ v14 x64 runtime; see the bundled installation guide.

Install Visual Studio 2022 C++ tools and the Windows SDK, Rust 1.98.0 for
`x86_64-pc-windows-msvc`, NSH 0.4.0 x64, huacnlee/cargo and native Strawberry
Perl. Git's MSYS Perl does not provide the complete OpenSSL build environment.
Keep Visual Studio ahead of Git's `usr/bin` in PATH: Git also ships `link.exe`.
When manually installing the Cargo fork, stage and rename its executable;
copying over the rustup cargo symlink can overwrite rustup itself.

```powershell
$env:NSH_BIN = '<NSH 0.4.0 directory>\bin\nsh.exe'
$env:PV_PERL_BIN = '<Strawberry Perl directory>\perl\bin'
.\tool\nsh_windows.ps1 check
.\tool\nsh_windows.ps1 -Command run -NshArguments @('App.tsx', '--target', 'windows')
.\tool\windows-desktop\package.ps1
```

The package script reuses the existing app icon and writes an unsigned preview
under `native-test-output/windows-desktop`; it does not publish a release.

The wrapper imports the Visual Studio environment for its own process, pins the
compiler, checks the Cargo fork, and restores its environment on exit. The
Cargo adapter copies generated runner executables into the location NSH expects;
it does not invoke upstream Cargo or change the fork's cache configuration.

Use only a fresh synthetic vault below TEMP for tests. Set
`PASSWORDVAULT_VAULT_DIRECTORY` explicitly before launching a QA application.
The default preview vault is below LOCALAPPDATA, separate from all Mac data.
Never transfer real vaults or signing materials for development acceptance.

Implemented platform adapters include native file dialogs, safe document-file
reads, Explorer navigation, minimize/restore, idle time, session and sleep events,
and write-through journal replacement. Touch ID is hidden. Browser and AI local
IPC, global shortcuts, terminal-script handoff and recovery-key printing are
not yet available on Windows; their controls are hidden or report unavailable.

Windows folder deletion durability relies on filesystem journaling: the Win32
API does not provide the POSIX directory-fsync operation used on Mac. Power-loss
recovery and user-private ACL acceptance remain required before production use.

For machines whose PowerShell policy restricts local scripts, launch a dedicated
`powershell.exe -NoProfile -ExecutionPolicy RemoteSigned` process for the build.
The scripts do not change machine or user execution policy.

For repeated builds, a verified x64 static OpenSSL installation can be reused
with `OPENSSL_DIR`, `OPENSSL_STATIC=1` and `OPENSSL_NO_VENDOR=1`. Keep that
installation outside Cargo's managed caches, which may reclaim build outputs.

On small VMs, set `CARGO_BUILD_JOBS=1` and run test and package builds sequentially
to avoid exhausting memory or pagefile space.
