#!/bin/bash
# Run sunfish.lua benchmarks/tests under LuaJ (the Java-based Lua interpreter).
#
# Downloads nothing; expects a JDK on PATH (or JAVA_HOME) and a luaj jar under
# .reference/ (see README). Jar pick order:
#   1. $LUAJ_JAR (explicit override)
#   2. .reference/luaj-fork-jse.jar  — the NYRDS/luaj fork (fiber library;
#      the launcher installs FiberLib, the engine yields on zero-thread fibers)
#   3. .reference/luaj-jse-3.0.2.jar — stock LuaJ 3.0.2 (coroutine yields)
#
# Use BENCH_SCALE to reduce iteration counts for the much slower LuaJ VM, e.g.:
#
#   BENCH_SCALE=0.01 benchmarks/run_luaj.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

REF=.reference
JAVA_BIN="${JAVA_HOME:+$JAVA_HOME/bin}"
JAR="${LUAJ_JAR:-$REF/luaj-fork-jse.jar}"
[ -f "$JAR" ] || JAR="$REF/luaj-jse-3.0.2.jar"

if [ ! -f "$JAR" ]; then
    echo "error: no luaj jar found in $REF" >&2
    echo "Expected $REF/luaj-fork-jse.jar or $REF/luaj-jse-3.0.2.jar" >&2
    echo "See README 'LuaJ (Java) benchmarks' to set it up." >&2
    exit 1
fi
command -v "${JAVA_BIN}java" >/dev/null 2>&1 || JAVA_BIN=""
JAVA="${JAVA_BIN}java"
JAVAC="${JAVA_BIN}javac"

# Compile the committed launcher if needed (classes stay in gitignored .reference).
mkdir -p "$REF"
if [ ! -f "$REF/LuajRun.class" ] || [ benchmarks/java/LuajRun.java -nt "$REF/LuajRun.class" ]; then
    "$JAVAC" -cp "$JAR" -d "$REF" benchmarks/java/LuajRun.java
fi

export BENCH_SCALE="${BENCH_SCALE:-0.01}"
SCRIPT="${1:-benchmarks/bench_sunfish.lua}"
shift || true
exec "$JAVA" -Dluaj.path="$PWD/?.lua;$PWD/tests/?.lua" \
    -cp "$REF:$JAR" LuajRun "$SCRIPT" "$@"
