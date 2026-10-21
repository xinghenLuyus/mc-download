$ErrorActionPreference = 'Stop'
$resolve = Join-Path $PSScriptRoot 'build-version.ps1'
function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}
$dev = & $resolve
Assert-Equal $dev.Label 'dev'
Assert-Equal $dev.BuildName '0.0.0'
Assert-Equal $dev.Numeric '0,0,0,0'
$release = & $resolve -Version 'v0.1.0'
Assert-Equal $release.Label '0.1.0'
Assert-Equal $release.BuildName '0.1.0'
Assert-Equal $release.Numeric '0,1,0,0'
Assert-Equal $release.Prerelease $false
$preview = & $resolve -Version 'v2.10.3-rc.1'
Assert-Equal $preview.Label '2.10.3-rc.1'
Assert-Equal $preview.BuildName '2.10.3'
Assert-Equal $preview.Numeric '2,10,3,0'
Assert-Equal $preview.Prerelease $true
Assert-Equal (& $resolve -Version $preview.Label).Label $preview.Label
foreach ($invalid in @('', 'v0.1', 'v01.2.3', 'v1.2.3.4', 'v65536.0.0', 'v1.2.3;echo', 'v1.2.3-')) {
    $rejected = $false
    try { $null = & $resolve -Version $invalid } catch { $rejected = $true }
    if (-not $rejected) { throw "Accepted invalid version '$invalid'." }
}
Write-Host 'Version checks passed: dev, tags, prereleases, Windows metadata and invalid inputs.'
