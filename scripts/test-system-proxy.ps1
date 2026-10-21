$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-toolchain.ps1')
$cmake = Get-WindowsCMake
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\windows\proxy'))
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\orther\cache\proxy-tests'))
& $cmake -S $source -B $build -A x64
if ($LASTEXITCODE -ne 0) { throw 'WinHTTP test configuration failed.' }
& $cmake --build $build --config Release
if ($LASTEXITCODE -ne 0) { throw 'WinHTTP test build failed.' }
& (Join-Path $build 'Release\mc_download_proxy_test.exe')
if ($LASTEXITCODE -ne 0) { throw 'WinHTTP native error-capture test failed.' }
# flutter_tester does not contain the runner's exports. Load the standalone test
# library there; normal application builds embed these functions in the EXE.
$libraryDirectory = Join-Path $build 'Release'
$env:Path = "$libraryDirectory;$env:Path"
if ($env:GITHUB_PATH) { $libraryDirectory | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8 }
