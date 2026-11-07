# Build the unsigned Windows x64 preview using shared metadata and the existing icon.
param([string] $OutDir = 'native-test-output\windows-desktop')
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
$output = if ([IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $root $OutDir }
$icon = Join-Path $root 'apps\macos-legacy\Resources\Assets.xcassets\AppIcon.appiconset\icon_512_2.png'
& (Join-Path $root 'tool\nsh_windows.ps1') -Command package -NshArguments @('App.tsx', '--target', 'windows', '--out', $output, '--icon', $icon)
$metadata = Get-Content (Join-Path $root 'apps\desktop\nsh.json') -Raw | ConvertFrom-Json
$bundle = Join-Path $output $metadata.name
$archive = Join-Path $output ($metadata.name + '.zip')
if (!(Test-Path (Join-Path $bundle ($metadata.name + '.exe')))) { throw 'NSH did not produce the expected executable' }
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $bundle 'LICENSE.txt') -Force
Copy-Item (Join-Path $root 'config\release\THIRD_PARTY_NOTICES.md') $bundle -Force
Copy-Item (Join-Path $root 'config\release\licenses') $bundle -Recurse -Force
# Zip entry names use forward slashes on every host, including Windows PowerShell.
Add-Type -AssemblyName System.IO.Compression
$staged = $archive + '.staged'
$stream = [IO.File]::Open($staged, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$writer = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem $bundle -File -Recurse) {
        $relative = $metadata.name + '/' + $file.FullName.Substring($bundle.Length + 1).Replace('\', '/')
        $entry = $writer.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
        $inputStream = [IO.File]::OpenRead($file.FullName)
        $entryStream = $entry.Open()
        try { $inputStream.CopyTo($entryStream) }
        finally { $entryStream.Dispose(); $inputStream.Dispose() }
    }
} finally { $writer.Dispose(); $stream.Dispose() }
Move-Item -LiteralPath $staged -Destination $archive -Force
Get-FileHash $archive -Algorithm SHA256
