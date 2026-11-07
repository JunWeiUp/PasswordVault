# Windows x64 build/run entry. On Windows ARM, use the x64 toolchain under emulation.
param(
    [ValidateSet('check', 'run', 'test', 'package')][string] $Command = 'check',
    [Parameter(ValueFromRemainingArguments = $true)][string[]] $NshArguments
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$app = Join-Path $root 'apps\desktop'
$channel = ((Get-Content (Join-Path $app 'rust-toolchain.toml') | Where-Object { $_ -match '^channel = ' }) -split '"')[1]
$toolchain = "$channel-x86_64-pc-windows-msvc"
$rustup = Join-Path $env:USERPROFILE '.cargo\bin\rustup.exe'
$cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
$nsh = $env:NSH_BIN
if (!$nsh) { $nsh = Join-Path $env:LOCALAPPDATA 'nsh\bin\nsh.exe' }
if (!(Test-Path $nsh) -or ((& $nsh --version) -notmatch '^nsh 0\.4\.0 ')) { throw 'Set NSH_BIN to the NSH 0.4.0 x64 executable' }
$previousToolchain = $env:RUSTUP_TOOLCHAIN
$previousUpdate = $env:CARGO_FORK_AUTO_UPDATE
try {
    $env:RUSTUP_TOOLCHAIN = $toolchain
    $env:CARGO_FORK_AUTO_UPDATE = '0'
    if ((& $cargo --version) -notmatch 'huacnlee/cargo') { throw 'huacnlee/cargo is required' }
} finally {
    $env:RUSTUP_TOOLCHAIN = $previousToolchain
    $env:CARGO_FORK_AUTO_UPDATE = $previousUpdate
}
$rustc = & $rustup which --toolchain $toolchain rustc
if ($LASTEXITCODE -ne 0) { throw "Install Rust $toolchain first" }
if ($Command -eq 'test') {
    $vault = $env:PASSWORDVAULT_VAULT_DIRECTORY
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$vault -or !([IO.Path]::GetFullPath($vault).StartsWith($temp, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Tests require a fresh synthetic PASSWORDVAULT_VAULT_DIRECTORY beneath TEMP'
    }
}
$saved = @{}
Get-ChildItem Env: | ForEach-Object { $saved[$_.Name] = $_.Value }
Push-Location $app
try {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = & $vswhere -latest -products '*' -property installationPath
    if (!$vs) { throw 'Visual Studio C++ tools and Windows SDK are required' }
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $setup = '"' + (Join-Path $vs 'Common7\Tools\VsDevCmd.bat') + '" -arch=x64 -host_arch=' + $hostArch + ' >nul && set'
    & cmd.exe /d /c $setup | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
    }
    if ($LASTEXITCODE -ne 0) { throw 'Visual Studio environment setup failed' }
    $env:RUSTUP_TOOLCHAIN = $toolchain
    $env:RUSTC = $rustc
    $env:CARGO = Join-Path $root 'tool\nsh-cargo\cargo.cmd'
    $env:CARGO_FORK_AUTO_UPDATE = '0'
    # Keep toolchains from sharing incompatible compiler metadata.
    $env:CARGO_SHARED_DEPS = '0'
    $env:PATH = (Join-Path $env:USERPROFILE '.cargo\bin') + ';' + $env:PATH
    if ($env:PV_PERL_BIN) { $env:PATH = $env:PV_PERL_BIN + ';' + $env:PATH }
    if ($Command -eq 'test') { $env:PV_DISABLE_HOTKEY = '1' }
    & $nsh $Command @NshArguments
    if ($LASTEXITCODE -ne 0) { throw "NSH $Command failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
    Get-ChildItem Env: | Where-Object { !$saved.ContainsKey($_.Name) } | ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process') }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
