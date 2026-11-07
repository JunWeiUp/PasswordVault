# Adapt the fork's fixed artifact location to the NSH runner's requested directory.
$ErrorActionPreference = 'Stop'
$forward = @($args)
$real = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
if ((& $real --version) -notmatch 'huacnlee/cargo') { throw 'huacnlee/cargo is required' }
& $real @forward
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
function Get-Option([string] $name) {
    for ($i = 0; $i -lt $forward.Count; $i++) {
        if ($forward[$i] -eq $name -and $i + 1 -lt $forward.Count) { return $forward[$i + 1] }
        if ($forward[$i].StartsWith($name + '=')) { return $forward[$i].Substring($name.Length + 1) }
    }
    return $null
}
$manifest = Get-Option '--manifest-path'
if (!$manifest) { $manifest = 'Cargo.toml' }
$directory = Split-Path ([IO.Path]::GetFullPath($manifest))
while ($directory -and (Split-Path $directory -Leaf) -ne 'rust') { $directory = Split-Path $directory }
if ($directory -and (Split-Path (Split-Path $directory) -Leaf) -eq '.nsh') {
    $destination = Get-Option '--target-dir'
    if (!$destination) { $destination = $env:CARGO_TARGET_DIR }
    if (!$destination) { $destination = Join-Path (Split-Path (Split-Path $directory)) 'target' }
    foreach ($buildProfile in @('debug', 'release')) {
        $source = Join-Path $directory "target\$buildProfile"
        $out = Join-Path $destination $buildProfile
        if ([IO.Path]::GetFullPath($source) -eq [IO.Path]::GetFullPath($out)) { continue }
        foreach ($binary in @(Get-ChildItem $source -Filter 'nsh-app-*.exe' -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Force $out | Out-Null
            Copy-Item $binary.FullName (Join-Path $out $binary.Name) -Force
        }
    }
}
exit 0
