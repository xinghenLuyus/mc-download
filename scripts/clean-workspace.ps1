$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$archive = Join-Path $root 'orther'
function Move-Generated([string]$Source, [string]$Destination) {
    $sourcePath = Join-Path $root $Source
    if (-not (Test-Path -LiteralPath $sourcePath)) { return }
    $target = Join-Path $archive $Destination
    if (Test-Path -LiteralPath $target) {
        $target = "$target-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    Move-Item -LiteralPath $sourcePath -Destination $target
}
Move-Generated '.dart_tool' 'cache/.dart_tool'
Move-Generated '.flutter-plugins-dependencies' 'cache/.flutter-plugins-dependencies'
Move-Generated '.flutter-plugins' 'cache/.flutter-plugins'
Move-Generated '.packages' 'cache/.packages'
Move-Generated '.idea' 'cache/.idea'
Move-Generated 'build' 'build'
Move-Generated 'coverage' 'cache/coverage'
Move-Generated '.upstream' 'upstream'
Move-Generated 'local-data' 'local-data'
Move-Generated 'windows/flutter/ephemeral' 'cache/windows-flutter-ephemeral'
Get-ChildItem -LiteralPath $root -File -Filter '*.iml' | ForEach-Object {
    Move-Generated $_.Name "cache/$($_.Name)"
}
Write-Host 'Generated files archived under orther/.'
