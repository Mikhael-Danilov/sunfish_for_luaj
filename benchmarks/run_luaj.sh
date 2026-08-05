#!/bin/bash
# Run sunfish.lua benchmarks under LuaJ (the Java-based Lua interpreter).
#
# Downloads nothing; expects the JDK and LuaJ jar already present under
# .reference/ (see README). Use BENCH_SCALE to reduce iteration counts for
# the much slower LuaJ VM, e.g.:
#
#   BENCH_SCALE=0.01 benchmarks/run_luaj.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

REF=.reference
JAVA="$REF/jdk-21.0.12+8/bin/java"
JAR="$REF/luaj-jse-3.0.2.jar"
SCRIPT="$REF/LuajRun.java"

if [ ! -x "$JAVA" ] || [ ! -f "$JAR" ]; then
    echo "error: LuaJ toolchain not found in $REF" >&2
    echo "Expected: $JAVA and $JAR" >&2
    echo "See README 'LuaJ (Java) benchmarks' to set it up." >&2
    exit 1
fi

# Compile the launcher if needed.
if [ ! -f "$REF/LuajRun.class" ] || [ "$SCRIPT" -nt "$REF/LuajRun.class" ]; then
    "$REF/jdk-21.0.12+8/bin/javac" -cp "$JAR" -d "$REF" "$SCRIPT"
fi

export BENCH_SCALE="${BENCH_SCALE:-0.01}"
SCRIPT="${1:-benchmarks/bench_sunfish.lua}"
shift || true
exec "$JAVA" -Dluaj.path="$PWD/?.lua;$PWD/tests/?.lua" \
    -cp "$REF:$JAR" LuajRun "$SCRIPT" "$@"
