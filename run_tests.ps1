# Miau Motel smoke test runner (Windows PowerShell).
#
# Runs every headless smoke test in Scripts/Test/ in a deterministic order
# and exits nonzero if any test fails or is skipped.
#
# Usage:
#   .\run_tests.ps1                      # uses the default Godot path below
#   .\run_tests.ps1 -Godot "C:\path\to\Godot_console.exe"
#   $env:GODOT = "C:\path\to\Godot_console.exe"; .\run_tests.ps1

param(
    [string]$Godot = $(if ($env:GODOT) { $env:GODOT } else { "C:\Users\Mauro\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" }),
    [string]$Filter = ""
)

$ErrorActionPreference = "Continue"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Deterministic order: keep this list in sync when adding smoke tests.
$Tests = @(
    "PrototypeSmokeTest",
    "PlayerCollisionSmokeTest",
    "CameraSmokeTest",
    "PlayerDirectionSmokeTest",
    "RoomWorldSmokeTest",
    "RoomTransitionSmokeTest",
    "MainRoomWorldSmokeTest",
    "RoomLayoutSmokeTest",
    "RoomConnectionSmokeTest",
    "RoomNeighborhoodSmokeTest",
    "SaveIntegritySmokeTest",
    "FloorSmokeTest",
    "FloorPersistenceSmokeTest",
    "FloorPanelSmokeTest",
    "FloorManagementSmokeTest",
    "CreationModeSmokeTest",
    "TileSmokeTest",
    "CarpetSmokeTest",
    "BuildingCatalogSmokeTest",
    "BuildingUiSmokeTest",
    "WorldSnapshotSmokeTest",
    "BuildOpsSmokeTest",
    "StructuralGuardSmokeTest",
    "FloorTransitionSmokeTest",
    "StructuralOpsSmokeTest",
    "FloorOpsSmokeTest",
    "ServerPersistenceSmokeTest",
    "SpawnPointSmokeTest",
    "PortalSmokeTest",
    "PortalTransitionSmokeTest",
    "PortalLifecycleSmokeTest",
    "TransitionOverlaySmokeTest",
    "AvatarPanelSmokeTest",
    "CombatGridSmokeTest",
    "CombatSessionSmokeTest",
    "CombatEncounterSmokeTest",
    "MutantCursedSmokeTest"
)

if ($Filter -ne "") {
    $Tests = @($Tests | Where-Object { $_ -like "*$Filter*" })
}

if ($Filter -ne "" -and $Tests.Count -eq 0) {
    Write-Error "No smoke tests match filter '$Filter'."
    exit 2
}

if (-not (Test-Path $Godot)) {
    Write-Error "Godot executable not found: $Godot`nPass -Godot <path> or set `$env:GODOT."
    exit 2
}

$failed = @()
$ran = 0
foreach ($test in $Tests) {
    $script = "res://Scripts/Test/$test.gd"
    if (-not (Test-Path (Join-Path $ProjectRoot "Scripts\Test\$test.gd"))) {
        Write-Host ("{0,-32} SKIPPED (script missing)" -f $test)
        $failed += "$test (missing)"
        continue
    }
    $ran++
    $output = & $Godot --headless --path $ProjectRoot -s $script 2>&1 | Out-String
    $marker = [regex]::Match($output, "[A-Z_]+_SMOKE: (OK|FAILED[^\r\n]*)")
    if ($LASTEXITCODE -eq 0 -and $marker.Success -and $marker.Groups[1].Value -eq "OK") {
        Write-Host ("{0,-32} OK" -f $test)
    } else {
        $reason = if ($marker.Success) { $marker.Groups[1].Value } else { "no SMOKE marker (exit $LASTEXITCODE)" }
        Write-Host ("{0,-32} FAIL: {1}" -f $test, $reason)
        $failed += $test
        # Surface script errors for debugging.
        $errors = ($output -split "`n" | Where-Object { $_ -match "SCRIPT ERROR|Parse Error|FAIL:" } | Select-Object -First 6)
        foreach ($line in $errors) { Write-Host "    $($line.Trim())" }
    }
}

Write-Host ""
if ($failed.Count -eq 0 -and $ran -eq $Tests.Count) {
    Write-Host "ALL TESTS PASSED ($ran/$($Tests.Count))"
    exit 0
} else {
    Write-Host "TESTS FAILED: $($failed -join ', ')"
    exit 1
}
