$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-toolchain.ps1')
$cmake = Get-WindowsCMake
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\orther\cache\portable-smoke'))
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\windows\bootstrap'))
$fixtureBuild = Join-Path $root 'fixture-build'
& $cmake -S $source -B $fixtureBuild -A x64 -DMCD_BUILD_FIXTURE=ON
if ($LASTEXITCODE -ne 0) { throw 'Fixture configuration failed.' }
& $cmake --build $fixtureBuild --config Release
if ($LASTEXITCODE -ne 0) { throw 'Fixture build failed.' }
$scenario = Join-Path $root ('run-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $scenario 'payload'
$distribution = Join-Path $scenario '便携 工具'
$unrelated = Join-Path $scenario 'unrelated-working-directory'
New-Item -ItemType Directory -Force -Path "$payload\data", $distribution, $unrelated | Out-Null
Copy-Item -LiteralPath (Join-Path $fixtureBuild 'Release\portable_fixture.exe') -Destination (Join-Path $payload 'mc_download.exe')
$asset = 'data\测试 asset.txt'
[IO.File]::WriteAllText((Join-Path $payload $asset), 'payload version one')
$launcher = Join-Path $distribution 'MC Download.exe'
& (Join-Path $PSScriptRoot 'package-portable.ps1') -RuntimeDirectory $payload -OutputFile $launcher -WorkDirectory (Join-Path $scenario 'package-v1') -Version v0.1.0
$data = Join-Path $distribution '.mcdownload'
New-Item -ItemType Directory -Force -Path $data | Out-Null
[IO.File]::WriteAllText((Join-Path $data 'settings.json'), 'settings must survive updates')
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
$versionOne = [Diagnostics.FileVersionInfo]::GetVersionInfo($launcher)
Assert-True ($versionOne.ProductVersion -eq '0.1.0') 'Portable product version does not match the tag.'
Assert-True ($versionOne.FileMinorPart -eq 1) 'Portable numeric version does not match the tag.'
function Start-Portable([string]$Application, [string]$Report, [int]$Hold = 0, [int]$Code = 0) {
    $arguments = '--report "{0}" --hold-ms {1} --exit-code {2} --text "a b" --trailing "C:\space dir\\" --quoted "say \"hello\""' -f $Report, $Hold, $Code
    return Start-Process -FilePath $Application -ArgumentList $arguments -WorkingDirectory $unrelated -PassThru
}
function Wait-Portable([Diagnostics.Process]$Child, [int]$Code = 0) {
    if (-not $Child.WaitForExit(60000)) {
        $Child.Kill($true)
        throw 'Portable launcher timed out (possible startup error dialog).'
    }
    $Child.WaitForExit()
    Assert-True ($Child.ExitCode -eq $Code) "Unexpected launcher exit code: $($Child.ExitCode), expected $Code"
}
function Read-Report([string]$Path) { return [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8) }
function Await-Report([string]$Path) {
    $limit = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ([DateTime]::UtcNow -gt $limit) { throw "No child report: $Path" }
        Start-Sleep -Milliseconds 50
    }
}
$report = Join-Path $scenario 'first report.txt'
Wait-Portable (Start-Portable $launcher $report)
$first = Read-Report $report
$runtime = Split-Path $first[2] -Parent
Assert-True ($first[0] -eq $data) 'Data directory moved inside the runtime.'
Assert-True ($first[1] -eq $runtime) 'Child did not start in the extracted runtime.'
Assert-True ($first -contains 'a b') 'Arguments containing spaces changed.'
Assert-True ($first -contains 'C:\space dir\') 'Trailing backslashes changed.'
Assert-True ($first -contains 'say "hello"') 'Quoted arguments changed.'
Assert-True ((Get-ChildItem -LiteralPath $distribution -File).Count -eq 1) 'Distribution contains loose dependencies.'
Assert-True ([IO.File]::ReadAllText((Join-Path $runtime $asset)) -eq 'payload version one') 'Unicode resource path was not preserved.'
$marker = (Get-Item -LiteralPath (Join-Path $runtime '.complete')).LastWriteTimeUtc
Wait-Portable (Start-Portable $launcher (Join-Path $scenario 'reuse.txt'))
Assert-True ((Get-Item -LiteralPath (Join-Path $runtime '.complete')).LastWriteTimeUtc -eq $marker) 'Cached runtime was unnecessarily extracted.'
Remove-Item -LiteralPath (Join-Path $runtime $asset)
Wait-Portable (Start-Portable $launcher (Join-Path $scenario 'repair.txt'))
Assert-True (Test-Path -LiteralPath (Join-Path $runtime $asset)) 'Missing resource was not repaired.'
Remove-Item -LiteralPath (Join-Path $runtime '.complete')
$partial = $runtime + '.partial-999999'
New-Item -ItemType Directory -Force -Path $partial | Out-Null
[IO.File]::WriteAllText((Join-Path $partial 'unfinished'), 'interrupted extraction')
Wait-Portable (Start-Portable $launcher (Join-Path $scenario 'recover.txt'))
Assert-True (-not (Test-Path -LiteralPath $partial)) 'Interrupted extraction was not cleaned up.'
Remove-Item -LiteralPath (Join-Path $data 'runtime') -Recurse -Force
$a = Start-Portable $launcher (Join-Path $scenario 'concurrent-a.txt') 600
$b = Start-Portable $launcher (Join-Path $scenario 'concurrent-b.txt') 600
Wait-Portable $a
Wait-Portable $b
Assert-True ((Get-ChildItem -LiteralPath (Join-Path $data 'runtime') -Directory).Count -eq 1) 'Concurrent launches produced incomplete or duplicate caches.'
# Different EXE names model two downloaded versions in the same portable folder.
[IO.File]::WriteAllText((Join-Path $payload $asset), 'payload version two')
$updated = Join-Path $distribution 'MC Download updated.exe'
& (Join-Path $PSScriptRoot 'package-portable.ps1') -RuntimeDirectory $payload -OutputFile $updated -WorkDirectory (Join-Path $scenario 'package-v2') -Version v0.2.0-rc.1
$versionTwo = [Diagnostics.FileVersionInfo]::GetVersionInfo($updated)
Assert-True ($versionTwo.ProductVersion -eq '0.2.0-rc.1') 'Portable prerelease label was lost.'
Assert-True ($versionTwo.FileMinorPart -eq 2) 'Portable prerelease numeric version was lost.'
$oldReport = Join-Path $scenario 'old active.txt'
$old = Start-Portable $launcher $oldReport 2000
Await-Report $oldReport
$newReport = Join-Path $scenario 'new active.txt'
$new = Start-Portable $updated $newReport 4000
Await-Report $newReport
$newRuntime = Split-Path (Read-Report $newReport)[2] -Parent
Wait-Portable $old
Assert-True (Test-Path -LiteralPath $newRuntime) 'Old version deleted an active new runtime.'
Wait-Portable $new
Assert-True ($newRuntime -ne $runtime) 'Updated payload reused the old runtime.'
Assert-True (-not (Test-Path -LiteralPath $runtime)) 'Unused old runtime was not removed.'
Assert-True ([IO.File]::ReadAllText((Join-Path $data 'settings.json')) -eq 'settings must survive updates') 'Update changed user settings.'
$relocated = Join-Path $scenario '移动 后'
New-Item -ItemType Directory -Path $relocated | Out-Null
$moved = Join-Path $relocated 'MC Download.exe'
Copy-Item -LiteralPath $updated -Destination $moved
$movedReport = Join-Path $scenario 'moved.txt'
Wait-Portable (Start-Portable $moved $movedReport 0 7) 7
Assert-True ((Read-Report $movedReport)[0] -eq (Join-Path $relocated '.mcdownload')) 'Relocated EXE kept the previous data directory.'
Write-Host 'Portable launcher checks passed: first run, Unicode paths, arguments, reuse, repair, interrupted extraction, concurrent launches, update, data preservation, relocation, exit code.'
