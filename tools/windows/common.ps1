# Shared paths for the Routine VR Windows tools.

$GameExe = 'Routine-Win64-Shipping'
$AppId = 606160
$RepoDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ProfileSrc = Join-Path $RepoDir "profile\$GameExe"
$ProfileDest = Join-Path $env:APPDATA "UnrealVRMod\$GameExe"
$PakFiles = @('PPV.pak', 'PPV.ucas', 'PPV.utoc', 'SML.pak', 'SML.ucas', 'SML.utoc')

# Routine's install folder, from Steam's library list; $null if not found.
function Find-GameDir {
    $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return $null }
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    $libs = @($steam)
    if (Test-Path $vdf) {
        foreach ($line in Get-Content $vdf) {
            if ($line -match '^\s*"path"\s*"(.*)"') { $libs += ($Matches[1] -replace '\\\\', '\') }
        }
    }
    foreach ($lib in $libs) {
        if (Test-Path (Join-Path $lib "steamapps\appmanifest_$AppId.acf")) {
            return Join-Path $lib 'steamapps\common\Routine'
        }
    }
    return $null
}

function Get-ModsDir {
    $game = Find-GameDir
    if (-not $game) { return $null }
    return Join-Path $game 'Routine\Content\Paks\~mods'
}
