param([string]$Version = 'dev')
$ErrorActionPreference = 'Stop'
if ($Version -eq 'dev') {
    return [pscustomobject]@{ Label = 'dev'; BuildName = '0.0.0'; Numeric = '0,0,0,0'; Prerelease = $false }
}
if ($Version -cnotmatch '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$') {
    throw 'Version must be dev or a version such as v0.1.0 / v0.1.0-rc.1.'
}
$major, $minor, $patch, $suffix = $Matches[1], $Matches[2], $Matches[3], $Matches[4]
foreach ($part in @($major, $minor, $patch)) {
    if ([decimal]$part -gt 65535) { throw 'Windows version components must not exceed 65535.' }
}
return [pscustomobject]@{
    Label = "$major.$minor.$patch$suffix"
    BuildName = "$major.$minor.$patch"
    Numeric = "$major,$minor,$patch,0"
    Prerelease = -not [string]::IsNullOrEmpty($suffix)
}
