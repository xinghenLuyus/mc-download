$ErrorActionPreference = 'Stop'
$build = Join-Path $PSScriptRoot 'build-windows.ps1'
$previousKey = $env:CURSEFORGE_API_KEY
$previousActions = $env:GITHUB_ACTIONS
$previousVersion = $env:MCD_APP_VERSION
$global:mcdCredentialBuild = $null
# Stop after the Flutter invocation so this tests production argument handling
# and cleanup without needing a Windows compiler or a real API credential.
function global:flutter {
    $global:LASTEXITCODE = 0
    if ($args[0] -ne 'build') { return }
    $defineArgument = @($args | Where-Object { $_ -like '--dart-define-from-file=*' })
    if ($defineArgument.Count -ne 1) { throw 'Missing temporary build defines.' }
    $path = $defineArgument[0].Substring('--dart-define-from-file='.Length)
    $global:mcdCredentialBuild = @{
        Path = $path
        Arguments = @($args)
        Defines = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    }
    throw 'fixture-build-stop'
}
function Run-Build([string]$Version, [bool]$Embed, [string]$ExpectedError = 'fixture-build-stop') {
    $global:mcdCredentialBuild = $null
    $caught = $false
    try { & $build -SkipChecks -Version $Version -EmbedCurseForgeKey:$Embed }
    catch {
        $caught = $true
        if (-not $_.Exception.Message.Contains($ExpectedError)) { throw 'Unexpected credential build failure.' }
    }
    if (-not $caught) { throw 'Mock build did not stop.' }
    if ($global:mcdCredentialBuild -and (Test-Path -LiteralPath $global:mcdCredentialBuild.Path)) { throw 'Credential define file was not deleted after failure.' }
    if ($env:MCD_APP_VERSION -cne $previousVersion) { throw 'Build version environment was not restored.' }
}
try {
    $env:GITHUB_ACTIONS = 'false'
    $env:CURSEFORGE_API_KEY = 'fixture-$quoted"key\with symbols'
    Run-Build 'dev' $true 'DEV builds cannot embed'
    if ($global:mcdCredentialBuild) { throw 'DEV injection reached Flutter.' }
    Run-Build 'dev' $false
    if ($global:mcdCredentialBuild.Defines.ContainsKey('MC_DOWNLOAD_CF_PAYLOAD') -or $global:mcdCredentialBuild.Defines.ContainsKey('MC_DOWNLOAD_CF_MASK')) { throw 'DEV received bundled authorization.' }
    Run-Build 'v0.1.0' $true
    if ($global:mcdCredentialBuild.Defines.MC_DOWNLOAD_VERSION -cne '0.1.0') { throw 'Release version was not propagated.' }
    $payload = $global:mcdCredentialBuild.Defines.MC_DOWNLOAD_CF_PAYLOAD
    $mask = $global:mcdCredentialBuild.Defines.MC_DOWNLOAD_CF_MASK
    $cipherBytes = [Convert]::FromBase64String($payload)
    $maskBytes = [Convert]::FromBase64String($mask)
    if ($cipherBytes.Length -ne $maskBytes.Length) { throw 'Credential parts have different lengths.' }
    for ($i = 0; $i -lt $cipherBytes.Length; $i++) { $cipherBytes[$i] = $cipherBytes[$i] -bxor $maskBytes[$i] }
    if ([Text.Encoding]::UTF8.GetString($cipherBytes) -cne $env:CURSEFORGE_API_KEY) { throw 'Credential encoding round-trip failed.' }
    if (($global:mcdCredentialBuild.Defines | ConvertTo-Json -Compress).Contains($env:CURSEFORGE_API_KEY)) { throw 'Plaintext credential leaked into build defines.' }
    Run-Build 'v0.1.0' $true
    if ($payload -ceq $global:mcdCredentialBuild.Defines.MC_DOWNLOAD_CF_PAYLOAD -or $mask -ceq $global:mcdCredentialBuild.Defines.MC_DOWNLOAD_CF_MASK) { throw 'Credential encoding was reused across builds.' }
    if ($global:mcdCredentialBuild.Arguments -notcontains '--obfuscate') { throw 'Release obfuscation was not enabled.' }
    if (($global:mcdCredentialBuild.Arguments -join ' ').Contains($env:CURSEFORGE_API_KEY)) { throw 'Credential leaked into command arguments.' }
    $env:CURSEFORGE_API_KEY = ''
    Run-Build 'v0.1.0' $true 'Configure the CURSEFORGE_API_KEY'
    if ($global:mcdCredentialBuild) { throw 'Missing release credential reached Flutter.' }
    $env:CURSEFORGE_API_KEY = "invalid`ncredential"
    Run-Build 'v0.1.0' $true 'must be a single line'
    Write-Host 'Release credential checks passed: DEV isolation, required secret, JSON escaping, private arguments and temporary file cleanup.'
} finally {
    $env:CURSEFORGE_API_KEY = $previousKey
    $env:GITHUB_ACTIONS = $previousActions
    $env:MCD_APP_VERSION = $previousVersion
    Remove-Item Function:\flutter -ErrorAction SilentlyContinue
    Remove-Variable mcdCredentialBuild -Scope Global -ErrorAction SilentlyContinue
}
