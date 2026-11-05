# Install the Routine VR UEVR profile on Windows.
#
# config.txt is merged, not replaced: keys set in the repo's config.txt win,
# every other key UEVR wrote is kept. The first install backs up the original
# config.txt so uninstall.ps1 can put it back. data\ (your Routine VR
# settings) is left alone.
#
#   install.ps1 [-PpvZip path\to\PPV-....zip]
param([string]$PpvZip = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

New-Item -ItemType Directory -Force -Path $ProfileDest | Out-Null
$marker = Join-Path $ProfileDest '.routine-vr-installed'
$config = Join-Path $ProfileDest 'config.txt'
$backup = Join-Path $ProfileDest 'config.txt.pre-routine-vr'

if (-not (Test-Path $marker)) {
    if (Test-Path $config) {
        Copy-Item $config $backup -Force
        Set-Content -Path $marker -Value 'config=backed-up'
    } else {
        Set-Content -Path $marker -Value 'config=created'
    }
}

# Everything but config.txt.
Get-ChildItem -Path $ProfileSrc -Recurse -File | Where-Object { $_.Name -ne 'config.txt' -or $_.DirectoryName -ne $ProfileSrc } | ForEach-Object {
    $rel = $_.FullName.Substring($ProfileSrc.Length).TrimStart('\')
    $target = Join-Path $ProfileDest $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item $_.FullName $target -Force
}

# Merge config.txt: repo keys first (they win), then existing keys the repo
# doesn't set. UEVR writes CRLF.
$repoLines = @(Get-Content (Join-Path $ProfileSrc 'config.txt') | Where-Object { $_ -ne '' })
$seen = @{}
foreach ($l in $repoLines) { $seen[$l.Split('=')[0]] = $true }
$merged = New-Object System.Collections.Generic.List[string]
$merged.AddRange([string[]]$repoLines)
if (Test-Path $config) {
    foreach ($l in Get-Content $config) {
        if ($l -ne '' -and -not $seen.ContainsKey($l.Split('=')[0])) { $merged.Add($l) }
    }
    Write-Host 'Merged profile settings into existing config.txt.'
}
[System.IO.File]::WriteAllText($config, (($merged -join "`r`n") + "`r`n"))

Write-Host "Installed profile to:`n  $ProfileDest"

if ($PpvZip -ne '') {
    $mods = Get-ModsDir
    if (-not $mods) { throw "Couldn't find Routine in your Steam libraries to install the PPV pak mod." }
    if (-not (Test-Path $PpvZip)) { throw "PPV zip not found: $PpvZip" }
    New-Item -ItemType Directory -Force -Path $mods | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $PpvZip))
    try {
        foreach ($want in $PakFiles) {
            $entry = $zip.Entries | Where-Object { $_.Name -eq $want } | Select-Object -First 1
            if (-not $entry) { throw "missing from zip: $want" }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $mods $want), $true)
            Write-Host "installed $want"
        }
    } finally { $zip.Dispose() }
    Write-Host "Pak mods installed to: $mods"
}
