param(
    [Parameter(Mandatory)][string]$RuntimeDirectory,
    [Parameter(Mandatory)][string]$OutputFile,
    [string]$WorkDirectory = (Join-Path $PSScriptRoot '..\orther\cache\portable')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-toolchain.ps1')
$cmake = Get-WindowsCMake
$runtime = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$work = [IO.Path]::GetFullPath($WorkDirectory)
$output = [IO.Path]::GetFullPath($OutputFile)
if (-not (Test-Path -LiteralPath (Join-Path $runtime 'mc_download.exe'))) { throw 'Runtime is missing mc_download.exe.' }
New-Item -ItemType Directory -Force -Path $work | Out-Null
$payloadFiles = Join-Path $work 'files'
if (Test-Path -LiteralPath $payloadFiles) { Remove-Item -LiteralPath $payloadFiles -Recurse -Force }
New-Item -ItemType Directory -Path $payloadFiles | Out-Null
$files = @(Get-ChildItem -LiteralPath $runtime -File -Recurse -Force | Sort-Object FullName)
if ($files.Count -gt 65000 -or ($files | Measure-Object Length -Sum).Sum -gt 1GB) { throw 'Portable runtime exceeds cabinet limits.' }
$directives = [Collections.Generic.List[string]]::new()
@(
    '.Set Cabinet=ON', '.Set Compress=ON', '.Set CompressionType=LZX', '.Set CompressionMemory=21',
    '.Set MaxDiskSize=0', '.Set MaxCabinetSize=0', '.Set MaxFolderSize=0',
    '.Set DiskDirectoryTemplate=.', '.Set CabinetNameTemplate=payload.cab',
    '.Set RptFileName=makecab.rpt', '.Set InfFileName=makecab.inf'
) | ForEach-Object { $directives.Add($_) }
$manifest = [Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $files.Count; $i++) {
    $relative = $files[$i].FullName.Substring($runtime.TrimEnd('\').Length + 1)
    if ($relative -match '[\r\n\t]' -or $relative -in @('.complete', '.in-use', 'payload.cab')) { throw "Reserved runtime filename: $relative" }
    $name = '{0:D6}' -f $i
    [IO.File]::Copy($files[$i].FullName, (Join-Path $payloadFiles $name))
    # Numeric cabinet names keep makecab independent of the system code page.
    $directives.Add(('"files\{0}" "{0}"' -f $name))
    $manifest.Add(('{0}' -f $files[$i].Length) + "`t" + $relative)
}
$cab = Join-Path $work 'payload.cab'
$manifestPath = Join-Path $work 'manifest.txt'
[IO.File]::WriteAllLines((Join-Path $work 'payload.ddf'), $directives, [Text.Encoding]::ASCII)
[IO.File]::WriteAllText($manifestPath, ($manifest -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
if (Test-Path -LiteralPath $cab) { Remove-Item -LiteralPath $cab -Force }
Push-Location $work
try {
    & "$env:SystemRoot\System32\makecab.exe" /F payload.ddf /V1
    if ($LASTEXITCODE -ne 0) { throw 'makecab failed.' }
} finally { Pop-Location }
$hash = [Security.Cryptography.SHA256]::Create()
try {
    $cabBytes = [IO.File]::ReadAllBytes($cab)
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    [void]$hash.TransformBlock($cabBytes, 0, $cabBytes.Length, $cabBytes, 0)
    [void]$hash.TransformFinalBlock($manifestBytes, 0, $manifestBytes.Length)
    $id = [BitConverter]::ToString($hash.Hash).Replace('-', '').ToLowerInvariant()
} finally { $hash.Dispose() }
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\windows\bootstrap'))
$build = Join-Path $work 'build'
& $cmake -S $source -B $build -A x64 "-DMCD_CAB_PATH=$($cab.Replace('\', '/'))" "-DMCD_MANIFEST_PATH=$($manifestPath.Replace('\', '/'))" "-DMCD_PAYLOAD_ID=$id"
if ($LASTEXITCODE -ne 0) { throw 'Portable launcher configuration failed.' }
& $cmake --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw 'Portable launcher build failed.' }
New-Item -ItemType Directory -Force -Path (Split-Path $output -Parent) | Out-Null
Copy-Item -LiteralPath (Join-Path $build 'Release\mc_download_portable.exe') -Destination $output -Force
Write-Host "Portable application: $output"
