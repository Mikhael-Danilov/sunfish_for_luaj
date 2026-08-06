#!/bin/bash
# benchmarks/run_selfplay_pairs.sh — paired same-game self-play A/B (median of N games).
#
# Runs the SAME game (same plies) for the baseline and modified engines, N pairs,
# alternating order to cancel cold-start variance, and reports the median TOTAL ms
# per variant plus the delta. Per the benchmark taste, single pairs are
# uninformative under LuaJ's +/-30% variance — use >= 5 pairs for 5-15% effects.
#
# Usage:
#   benchmarks/run_selfplay_pairs.sh <base_dir> <mod_dir> <plies> <pairs>
#
#   base_dir / mod_dir   dirs containing sunfish.lua (baseline / modified)
#   plies                game length per pair (e.g. 8; 40 is a full game ~13min/variant)
#   pairs                number of paired games (>= 5 for meaningful medians)

set -euo pipefail
cd "$(dirname "$0")/.."

BASE_DIR="${1:?usage: run_selfplay_pairs.sh <base_dir> <mod_dir> <plies> <pairs>}"
MOD_DIR="${2:?}"
PLIES="${3:-8}"
PAIRS="${4:-5}"

export SUNFISH_NO_YIELD="${SUNFISH_NO_YIELD:-1}"

echo "# self-play pairs: plies=$PLIES pairs=$PAIRS no_yield=$SUNFISH_NO_YIELD"
for ((p = 1; p <= PAIRS; p++)); do
    if ((p % 2 == 1)); then
        b=$(SELFPLAY_PLIES=$PLIES benchmarks/ab_luaj.sh benchmarks/selfplay.lua "$BASE_DIR" "$MOD_DIR" 1 2>&1 | grep -E "TOTAL" | sed 's/.*TOTAL[^0-9]*\([0-9.]*\) ms.*/\1/')
        m=$(SELFPLAY_PLIES=$PLIES benchmarks/ab_luaj.sh benchmarks/selfplay.lua "$MOD_DIR" "$BASE_DIR" 1 2>&1 | grep -E "TOTAL" | sed 's/.*TOTAL[^0-9]*\([0-9.]*\) ms.*/\1/')
    else
        m=$(SELFPLAY_PLIES=$PLIES benchmarks/ab_luaj.sh benchmarks/selfplay.lua "$MOD_DIR" "$BASE_DIR" 1 2>&1 | grep -E "TOTAL" | sed 's/.*TOTAL[^0-9]*\([0-9.]*\) ms.*/\1/')
        b=$(SELFPLAY_PLIES=$PLIES benchmarks/ab_luaj.sh benchmarks/selfplay.lua "$BASE_DIR" "$MOD_DIR" 1 2>&1 | grep -E "TOTAL" | sed 's/.*TOTAL[^0-9]*\([0-9.]*\) ms.*/\1/')
    fi
    echo "pair $p: base=${b:-ERR}ms mod=${m:-ERR}ms delta=$(awk -v b="$b" -v m="$m" 'BEGIN{ if (b>0) printf "%.1f%%", (m-b)/b*100; else print "n/a" }' 2>/dev/null || echo n/a)"
done
