#!/bin/bash
# benchmarks/ab_luaj.sh — same-JVM alternating A/B runner for sunfish.lua under LuaJ.
#
# The project's established methodology (docs/luaj-optimization-plan.md) is a
# same-JVM alternating A/B: baseline and modified run twice per round, cold JVM
# each, alternating order, to cancel LuaJ's +/-30% cold-start variance.
#
# Usage:
#   benchmarks/ab_luaj.sh <script.lua> <baseline_dir> <modified_dir> [rounds]
#
#   script.lua      the benchmark script (bench_sunfish.lua or selfplay.lua)
#   baseline_dir    dir containing the BASELINE sunfish.lua (often the repo root)
#   modified_dir    dir containing the MODIFIED sunfish.lua (a second checkout)
#   rounds          number of alternating rounds (default 3)
#
# Each variant runs in a SEPARATE JVM (require caches by module name, so loading
# two engines in one process shares module-level precomputed tables — the
# benchmark taste says to run variants in separate processes). BENCH_SCALE and
# SUNFISH_NO_YIELD pass through for the inner benchmark.
#
# Output: one line per round per variant with the ai_move ms (or self-play TOTAL
# ms), alternating order. The paired runner (run_selfplay_pairs.sh) aggregates
# self-play games into a median.

set -euo pipefail
cd "$(dirname "$0")/.."

REF=.reference
JAVA="$REF/jdk-21.0.12+8/bin/java"
JAR="$REF/luaj-jse-3.0.2.jar"
SCRIPT="$REF/LuajRun.java"

if [ ! -x "$JAVA" ] || [ ! -f "$JAR" ]; then
    echo "error: LuaJ toolchain not found in $REF" >&2
    exit 1
fi
if [ ! -f "$REF/LuajRun.class" ] || [ "$SCRIPT" -nt "$REF/LuajRun.class" ]; then
    "$JAVA" -cp "$JAR" -d "$REF" "$SCRIPT" >/dev/null 2>&1 || true
fi

SCRIPT_FILE="${1:?usage: ab_luaj.sh <script.lua> <base_dir> <mod_dir> [rounds]}"
BASE_DIR="${2:?}"
MOD_DIR="${3:?}"
ROUNDS="${4:-3}"

export BENCH_SCALE="${BENCH_SCALE:-0.01}"
export SUNFISH_NO_YIELD="${SUNFISH_NO_YIELD:-1}"

# Run one variant cold and capture the "TOTAL" or "ai_move" line.
# For selfplay.lua, pass the variant's engine dir + plies (SELFPLAY_PLIES).
run_once() {
    local dir="$1"
    local tag="$2"
    local script_args=("$SCRIPT_FILE")
    if [[ "$SCRIPT_FILE" == *selfplay* ]]; then
        script_args+=("$dir" "${SELFPLAY_PLIES:-40}" "$tag")
    fi
    out=$("$JAVA" -Dluaj.path="$dir/?.lua;$PWD/tests/?.lua" \
        -cp "$REF:$JAR" LuajRun "${script_args[@]}" 2>&1)
    echo "$out" | grep -E "TOTAL|ai_move|ai_move " | head -1 | sed "s/^/$tag: /"
}

echo "# A/B: $(basename "$SCRIPT_FILE")  rounds=$ROUNDS  scale=$BENCH_SCALE  no_yield=$SUNFISH_NO_YIELD"
for ((r = 1; r <= ROUNDS; r++)); do
    if ((r % 2 == 1)); then
        run_once "$BASE_DIR" "round $r base"
        run_once "$MOD_DIR"  "round $r mod"
    else
        run_once "$MOD_DIR"  "round $r mod"
        run_once "$BASE_DIR" "round $r base"
    fi
done
