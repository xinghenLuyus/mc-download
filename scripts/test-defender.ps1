param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$ReportFile,
    [string]$SourceRunId = $env:GITHUB_RUN_ID
)
$ErrorActionPreference = 'Stop'
$reportPath = [IO.Path]::GetFullPath($ReportFile)
New-Item -ItemType Directory -Force -Path (Split-Path $reportPath -Parent) | Out-Null
$report = [ordered]@{
    timeUtc = [DateTime]::UtcNow.ToString('o')
    scannerCommit = $env:GITHUB_SHA
    sourceRunId = $SourceRunId
    target = [IO.Path]::GetFullPath($Path)
    status = 'not_run'
    binaries = @()
}
try {
    $target = Get-Item -LiteralPath $Path
    $files = if ($target.PSIsContainer) { Get-ChildItem -LiteralPath $target.FullName -File -Recurse } else { @($target) }
    $report.binaries = @($files | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object {
        [ordered]@{
            path = if ($target.PSIsContainer) { [IO.Path]::GetRelativePath($target.FullName, $_.FullName) } else { $_.Name }
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            length = $_.Length
        }
    })
    if ($report.binaries.Count -eq 0) {
        throw 'No EXE or DLL found to scan; verify the selected build artifact.'
    }
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        $report.status = 'unavailable'
        Write-Warning 'Microsoft Defender is unavailable; this is NOT a passed scan. See the diagnostic artifact.'
        return
    }
    $status = Get-MpComputerStatus
    $report.engine = $status.AMEngineVersion
    $report.signatures = $status.AntivirusSignatureVersion
    if ($status.AntivirusSignatureLastUpdated) {
        $report.signatureUpdatedUtc = $status.AntivirusSignatureLastUpdated.ToUniversalTime().ToString('o')
    }
    if (-not $status.AMServiceEnabled -or -not $status.AntivirusEnabled) {
        $report.status = 'unavailable'
        Write-Warning 'Microsoft Defender is inactive; this is NOT a passed scan. See the diagnostic artifact.'
        return
    }
    $scanner = $null
    $platform = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    if (Test-Path -LiteralPath $platform) {
        $scanner = Get-ChildItem -LiteralPath $platform -Directory | Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'MpCmdRun.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $scanner) { $scanner = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe' }
    if (-not (Test-Path -LiteralPath $scanner)) {
        $report.status = 'unavailable'
        Write-Warning 'MpCmdRun.exe is unavailable; this is NOT a passed scan.'
        return
    }
    $report.scanner = $scanner
    # Scan the actual bundle, including archives and excluded paths. This option
    # preserves samples for diagnosis; it does not turn off real-time protection.
    $report.scanOutput = @(& $scanner -Scan -ScanType 3 -File $target.FullName -DisableRemediation 2>&1 | ForEach-Object { $_.ToString() })
    $report.exitCode = $LASTEXITCODE
    $report.scanOutput | ForEach-Object { Write-Host $_ }
    if ($report.exitCode -ne 0) {
        $report.status = 'detection_or_scan_error'
        throw "Defender rejected the scan (exit $($report.exitCode)). Inspect $reportPath; the build will not be published."
    }
    $report.status = 'passed'
} catch {
    if ($report.status -eq 'not_run') { $report.status = 'error' }
    $report.error = $_.Exception.Message
    throw
} finally {
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Host "Defender diagnostic: $reportPath [$($report.status)]"
}
