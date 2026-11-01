<#
.SYNOPSIS
    Gate 0 for more than two players: does Phantom Blade Zero allow several player units in one fight?

    Spawns copies of player 1 around them (the mod's own "units <n>" command), with a thug beside them, and reads the
    answer out of the mod log: units accepted by the game, units still alive, enemies that took each unit into their
    hatred list, units that took damage, and whether the game's own error panel appeared.
    Nothing here touches the network: run it in single player. docs/MULTIPLAYER.md explains what each result means.

.PARAMETER Counts
    How many units to try, in order. Default 1,3: a single extra unit (what co-op already does with a ghost) and
    three (a full party of four).

.PARAMETER Settle
    Seconds to wait after spawning before reading the result, so enemies have time to fight the units.

.EXAMPLE
    .\tools\mp-units.ps1
    .\tools\mp-units.ps1 -Counts 3,5 -Settle 15
#>
param(
    [int[]]$Counts = @(1, 3),
    [double]$Settle = 8,
    [string]$Enemy = 'BP_Monster_MaleThug_Sword_Blue',
    [string]$GameWin64
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'find-game.ps1')
if (-not $GameWin64) {
    $GameWin64 = Find-PbzGame
    if (-not $GameWin64) { throw "Phantom Blade Zero wasn't found in your Steam libraries. Run again with -GameWin64 '<Steam library>\steamapps\common\PBZ\platform\steam'." }
}
. (Join-Path $PSScriptRoot 'mod-link.ps1') -GameWin64 $GameWin64 -ProcessName 'PBZ'

if (-not (Wait-Gameplay -TimeoutSec 120)) {
    throw "The game never reported player 1. Load a save, get into gameplay, and run this again."
}

function Send-And-Read([string]$Command, [double]$Wait) {
    $t0 = Get-Date
    Send-ModCommand $Command
    Start-Sleep -Milliseconds ([int]($Wait * 1000))
    @(Get-ModLog -Since $t0 -Last 400 | Where-Object { $_ -match 'units:|Spawned|error panel' } |
        ForEach-Object { $_ -replace '^.*?\[PBZCoop\] ', '' })
}

$verdicts = @()
foreach ($n in $Counts) {
    Write-Output "`n== $n extra unit(s)"
    Send-And-Read 'units 0' 0.6 | Out-Null
    # One thug, so the units are in a real fight and not standing in an empty field. (Not one per count: a leftover
    # thug from the previous round would make the next round's numbers read differently.)
    if ($n -eq $Counts[0]) {
        Send-And-Read "spawnenemy $Enemy 400" 1.5 | Out-Null
    }
    $spawn = Send-And-Read "units $n" 2.0
    $spawn | ForEach-Object { Write-Output "  $_" }
    Start-Sleep -Seconds $Settle
    $after = Send-And-Read 'units' 2.0
    $after | ForEach-Object { Write-Output "  $_" }

    $alive = 0
    if (($after -join ' ') -match 'units: \d+ spawned, (\d+) alive') { $alive = [int]$Matches[1] }
    $damaged = 0
    if (($after -join ' ') -match '(\d+) took damage') { $damaged = [int]$Matches[1] }
    $hated = 0
    if (($after -join ' ') -match '(\d+) hated by an enemy') { $hated = [int]$Matches[1] }
    $panel = ($after -join ' ') -match 'error panel: VISIBLE'
    $ok = ($alive -eq $n) -and -not $panel
    $verdicts += [pscustomobject]@{ Units = $n; Alive = $alive; Damaged = $damaged; Hated = $hated; Panel = $panel; Ok = $ok }
    Write-Output ("  => " + $(if ($ok) { "PASS" } else { "FAIL" }) + ": $alive/$n alive, $hated hated, $damaged damaged" +
        $(if ($panel) { ", the game's error panel is up" } else { "" }))
    Send-And-Read 'units 0' 0.6 | Out-Null
}

Write-Output "`n== result"
$verdicts | Format-Table -AutoSize | Out-String | Write-Output
if (@($verdicts | Where-Object { -not $_.Ok }).Count -eq 0) {
    Write-Output "All counts held. Stage 1 of docs/MULTIPLAYER.md is worth starting."
} else {
    Write-Output "At least one count failed: read docs/MULTIPLAYER.md, 'Gate 0', before starting the networking work."
}
