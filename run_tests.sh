#!/usr/bin/env bash
# Miau Motel smoke test runner (Linux/macOS/Git Bash).
#
# Runs every headless smoke test in Scripts/Test/ in a deterministic order
# and exits nonzero if any test fails or is skipped.
#
# Usage:
#   ./run_tests.sh
#   GODOT=/path/to/godot ./run_tests.sh
#   ./run_tests.sh RoomWorld        # run only tests matching a substring

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT="${GODOT:-godot}"
FILTER="${1:-}"

TESTS=(
    PrototypeSmokeTest
    PlayerCollisionSmokeTest
    CameraSmokeTest
    PlayerDirectionSmokeTest
    RoomWorldSmokeTest
    RoomTransitionSmokeTest
    MainRoomWorldSmokeTest
    RoomLayoutSmokeTest
    RoomConnectionSmokeTest
    RoomNeighborhoodSmokeTest
    SaveIntegritySmokeTest
    FloorSmokeTest
    FloorPersistenceSmokeTest
    FloorPanelSmokeTest
    CreationModeSmokeTest
    TileSmokeTest
    CarpetSmokeTest
    BuildingCatalogSmokeTest
    BuildingUiSmokeTest
)

if [ -n "$FILTER" ]; then
    FILTERED=()
    for t in "${TESTS[@]}"; do
        case "$t" in *"$FILTER"*) FILTERED+=("$t");; esac
    done
    TESTS=("${FILTERED[@]}")
fi

if [ -n "$FILTER" ] && [ ${#TESTS[@]} -eq 0 ]; then
    echo "No smoke tests match filter '$FILTER'." >&2
    exit 2
fi

if ! command -v "$GODOT" >/dev/null 2>&1 && [ ! -x "$GODOT" ]; then
    echo "Godot executable not found: $GODOT" >&2
    echo "Set GODOT=/path/to/godot or pass it as the first argument environment." >&2
    exit 2
fi

FAILED=()
RAN=0
TOTAL=${#TESTS[@]}
for test in "${TESTS[@]}"; do
    script="res://Scripts/Test/$test.gd"
    if [ ! -f "$PROJECT_ROOT/Scripts/Test/$test.gd" ]; then
        printf '%-32s SKIPPED (script missing)\n' "$test"
        FAILED+=("$test (missing)")
        continue
    fi
    RAN=$((RAN + 1))
    output=$("$GODOT" --headless --path "$PROJECT_ROOT" -s "$script" 2>&1)
    code=$?
    marker=$(printf '%s\n' "$output" | grep -oE '[A-Z_]+_SMOKE: (OK|FAILED[^[:space:]]*)' | head -1)
    case "$marker" in
        *": OK")
            if [ $code -eq 0 ]; then
                printf '%-32s OK\n' "$test"
                continue
            fi
            ;;
    esac
    reason="$marker"
    [ -z "$reason" ] && reason="no SMOKE marker (exit $code)"
    printf '%-32s FAIL: %s\n' "$test" "$reason"
    FAILED+=("$test")
    printf '%s\n' "$output" | grep -E 'SCRIPT ERROR|Parse Error|FAIL:' | head -6 | sed 's/^/    /'
done

echo ""
if [ ${#FAILED[@]} -eq 0 ] && [ "$RAN" -eq "$TOTAL" ]; then
    echo "ALL TESTS PASSED ($RAN/$TOTAL)"
    exit 0
else
    echo "TESTS FAILED: ${FAILED[*]}"
    exit 1
fi
