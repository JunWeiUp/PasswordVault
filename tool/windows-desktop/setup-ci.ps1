# Install pinned build tools on an ephemeral Windows x64 runner.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:CARGO_FORK_AUTO_UPDATE = '0'
$env:RUSTUP_TOOLCHAIN = '1.98.0-x86_64-pc-windows-msvc'
& rustup toolchain install $env:RUSTUP_TOOLCHAIN --profile minimal
if ($LASTEXITCODE -ne 0) { throw 'Rust installation failed' }
$installer = Join-Path $env:RUNNER_TEMP 'cargo-install.ps1'
Invoke-WebRequest 'https://huacnlee.github.io/cargo/install.ps1' -OutFile $installer
& $installer -Version '0.102.0-9'
if ((& "$env:USERPROFILE\.cargo\bin\cargo.exe" --version) -notmatch 'huacnlee/cargo') { throw 'Cargo fork missing' }
$base = 'https://github.com/longbridge/nsh/releases/download/v0.4.0/nsh-windows-x86_64.zip'
$archive = Join-Path $env:RUNNER_TEMP 'nsh.zip'
Invoke-WebRequest $base -OutFile $archive
$checksum = (Invoke-WebRequest "$base.sha256").Content
if ($checksum -is [byte[]]) { $checksum = [Text.Encoding]::ASCII.GetString($checksum) }
$expected = ($checksum.Trim() -split '\s+')[0]
if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $expected) { throw 'NSH checksum mismatch' }
$tools = Join-Path $env:RUNNER_TEMP 'passwordvault-tools'
Expand-Archive $archive $tools
$nsh = Join-Path $tools 'nsh\bin\nsh.exe'
if ((& $nsh --version) -notmatch '^nsh 0\.4\.0 ') { throw 'Wrong NSH version' }
if (!$env:VCPKG_INSTALLATION_ROOT) { throw 'Windows runner must provide vcpkg' }
& "$env:VCPKG_INSTALLATION_ROOT\vcpkg.exe" install openssl:x64-windows-static-md --disable-metrics
if ($LASTEXITCODE -ne 0) { throw 'OpenSSL build failed' }
$ssl = Join-Path $env:VCPKG_INSTALLATION_ROOT 'installed\x64-windows-static-md'
@("NSH_BIN=$nsh", "OPENSSL_DIR=$ssl", 'OPENSSL_STATIC=1', 'OPENSSL_NO_VENDOR=1', 'CARGO_SHARED_DEPS=0', 'CARGO_BUILD_JOBS=2', 'CARGO_FORK_AUTO_UPDATE=0') | Add-Content $env:GITHUB_ENV
