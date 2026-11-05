# Remove the Routine VR UEVR profile (and the PPV/SML pak mod) on Windows.
#
# Deletes the mod's scripts and user_script.txt, and puts config.txt back as
# it was before the first install. Your Routine VR settings in data\ are kept
# unless you pass -RemoveSettings. UEVR itself is left alone.
#
#   uninstall.ps1 [-RemoveSettings]
param([switch]$RemoveSettings)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (Test-Path $ProfileDest) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $ProfileDest 'scripts\routine_vr')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $ProfileDest 'scripts\routine_vr.lua')
    $scripts = Join-Path $ProfileDest 'scripts'
    if ((Test-Path $scripts) -and -not (Get-ChildItem $scripts)) { Remove-Item $scripts }
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $ProfileDest 'user_script.txt')

    $marker = Join-Path $ProfileDest '.routine-vr-installed'
    $config = Join-Path $ProfileDest 'config.txt'
    $backup = Join-Path $ProfileDest 'config.txt.pre-routine-vr'
    if (Test-Path $backup) {
        Move-Item -Force $backup $config
        Write-Host 'Restored your original config.txt.'
    } elseif ((Test-Path $marker) -and ((Get-Content $marker) -match 'config=created')) {
        Remove-Item -Force -ErrorAction SilentlyContinue $config
        Write-Host 'Removed config.txt (the mod created it; UEVR makes a fresh one).'
    } else {
        Write-Host 'No config.txt backup found; left config.txt as it is.'
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $marker

    if ($RemoveSettings) {
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $ProfileDest 'data\routine_vr*.json')
        $data = Join-Path $ProfileDest 'data'
        if ((Test-Path $data) -and -not (Get-ChildItem $data)) { Remove-Item $data }
        Write-Host 'Removed Routine VR settings and recordings.'
    }
    Write-Host "Routine VR removed from:`n  $ProfileDest"
} else {
    Write-Host "No UEVR profile at $ProfileDest; nothing to remove."
}

$mods = Get-ModsDir
if ($mods -and (Test-Path $mods)) {
    foreach ($f in $PakFiles) { Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $mods $f) }
    if (-not (Get-ChildItem $mods)) { Remove-Item $mods }
    Write-Host 'Removed the PPV/SML pak mod files.'
}
