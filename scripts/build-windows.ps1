param([switch]$SkipChecks)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
function Invoke-Flutter {
    & flutter @args
    if ($LASTEXITCODE -ne 0) { throw "flutter failed with exit code $LASTEXITCODE" }
}
Invoke-Flutter pub get
if (-not $SkipChecks) {
    Invoke-Flutter analyze
    Invoke-Flutter test --no-pub
}
Invoke-Flutter build windows --release
$release = Join-Path $PWD 'build\windows\x64\runner\Release'
# Flutter desktop also needs the Microsoft C++ runtime on a clean PC.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'vswhere.exe missing; install Visual Studio Desktop development with C++.' }
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$redist = Join-Path $vs 'VC\Redist\MSVC'
$crt = Get-ChildItem $redist -Directory | Sort-Object Name -Descending | ForEach-Object {
    Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue
} | Select-Object -First 1
if (-not $crt) { throw 'Microsoft x64 C++ runtime not found in Visual Studio redist directory.' }
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
    Copy-Item (Join-Path $crt.FullName $dll) -Destination $release
}
Copy-Item LICENSE, README.md -Destination $release
$output = Join-Path $PWD 'orther\releases\MC Download.exe'
& (Join-Path $PSScriptRoot 'package-portable.ps1') -RuntimeDirectory $release -OutputFile $output
& (Join-Path $PSScriptRoot 'clean-workspace.ps1')
Write-Host "Built: $output"
