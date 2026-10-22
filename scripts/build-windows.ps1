param([switch]$SkipChecks, [string]$Version = 'dev', [switch]$EmbedCurseForgeKey)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$versionInfo = & (Join-Path $PSScriptRoot 'build-version.ps1') -Version $Version
if ($EmbedCurseForgeKey -and $versionInfo.Label -eq 'dev') { throw 'DEV builds cannot embed CurseForge credentials.' }
$credential = ''
if ($EmbedCurseForgeKey) {
    $credential = "$env:CURSEFORGE_API_KEY".Trim()
    if ([string]::IsNullOrWhiteSpace($credential)) { throw 'Configure the CURSEFORGE_API_KEY GitHub Actions secret before building a tagged release.' }
    if ($credential -match '[\r\n]') { throw 'CURSEFORGE_API_KEY must be a single line.' }
}
function Invoke-Flutter {
    & flutter @args
    if ($LASTEXITCODE -ne 0) { throw "flutter failed with exit code $LASTEXITCODE" }
}
Invoke-Flutter pub get
if (-not $SkipChecks) {
    Invoke-Flutter analyze
    & (Join-Path $PSScriptRoot 'test-system-proxy.ps1')
    Invoke-Flutter test --no-pub
}
$defineFile = Join-Path ([IO.Path]::GetTempPath()) ('mc-download-defines-' + [guid]::NewGuid().ToString('N') + '.json')
$previousVersion = $env:MCD_APP_VERSION
try {
    $env:MCD_APP_VERSION = $versionInfo.Label
    $defines = @{ MC_DOWNLOAD_VERSION = $versionInfo.Label }
    $arguments = @('build', 'windows', '--release', "--build-name=$($versionInfo.BuildName)", '--build-number=0', "--dart-define-from-file=$defineFile")
    if ($EmbedCurseForgeKey) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($credential)
        $pad = [byte[]]::new($bytes.Length)
        $encoded = [byte[]]::new($bytes.Length)
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $random.GetBytes($pad) } finally { $random.Dispose() }
        for ($i = 0; $i -lt $bytes.Length; $i++) { $encoded[$i] = $bytes[$i] -bxor $pad[$i] }
        $defines.MC_DOWNLOAD_CF_PAYLOAD = [Convert]::ToBase64String($encoded)
        $defines.MC_DOWNLOAD_CF_MASK = [Convert]::ToBase64String($pad)
        $arguments += @('--obfuscate', "--split-debug-info=$(Join-Path $PWD 'orther\symbols')/$($versionInfo.Label)")
        if ($env:GITHUB_ACTIONS -eq 'true') {
            Write-Host "::add-mask::$credential"
            foreach ($name in @('MC_DOWNLOAD_CF_PAYLOAD', 'MC_DOWNLOAD_CF_MASK')) {
                Write-Host "::add-mask::$($defines[$name])"
                $encodedDefine = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$name=$($defines[$name])"))
                Write-Host "::add-mask::$encodedDefine"
            }
        }
    }
    [IO.File]::WriteAllText($defineFile, ($defines | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    Invoke-Flutter @arguments
} finally {
    $env:MCD_APP_VERSION = $previousVersion
    $credential = $null
    if (Test-Path -LiteralPath $defineFile) { Remove-Item -LiteralPath $defineFile -Force }
}
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
$output = Join-Path $PWD "orther\releases\MC Download $($versionInfo.Label).exe"
& (Join-Path $PSScriptRoot 'package-portable.ps1') -RuntimeDirectory $release -OutputFile $output -Version $versionInfo.Label
& (Join-Path $PSScriptRoot 'clean-workspace.ps1')
Write-Host "Built: $output"
