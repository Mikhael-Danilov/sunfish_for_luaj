# sunfish.lua — tests & benchmarks

Zero-dependency test suite and benchmarks for the chess engine in `sunfish.lua`,
covering its public API only:

- `sunfish.new()` — fresh starting position
- `sunfish.move(game, mv)` — apply a legal move (returns the next position, or `false`)
- `sunfish.ai_move(game)` — engine search (returns position, move string, score)
- `sunfish.store_data(game)` / `sunfish.restore_data(data)` — serialize/deserialize a position
- `sunfish.move_2_cell(i)` / `sunfish.cell_2_move(cell)` — square index <-> coordinate
- `sunfish.MATE_VALUE`

## Requirements

- Lua 5.1+ or LuaJIT (both tested). No external dependencies.
- For the cross-validation test (`tests/compare_python_chess.py`): Python 3
  with `python-chess` installed (`pip install python-chess`).

## Running

```sh
# Tests
lua tests/test_sunfish.lua        # or: lua5.1, luajit
lua tests/test_endgames.lua       # endgame correctness tests

# Cross-validate legal-move generation against python-chess
python3 tests/compare_python_chess.py

# Benchmarks
luajit benchmarks/bench_sunfish.lua     # fastest
lua5.1 benchmarks/bench_sunfish.lua
BENCH_SCALE=0.01 benchmarks/run_luaj.sh # LuaJ (Java) - much slower VM
```

The benchmark honors `BENCH_SCALE` (0..1) to shrink iteration counts for slow
interpreters; the LuaJ wrapper defaults to 0.01 so a run finishes in ~1 minute.

## LuaJ (Java) benchmarks

LuaJ is the Java-based Lua interpreter (luaj.org / `luaj/luaj` on GitHub),
not LuaJIT. The engine was tuned for "Luaj interpreter mode", so run the
benchmarks under it:

```sh
# One-time setup (Java 21 + LuaJ 3.0.2 live under .reference/, gitignored):
mkdir -p .reference
curl -sL -o .reference/jdk.tar.gz "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12%2B8/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12_8.tar.gz"
curl -sL -o .reference/luaj-jse-3.0.2.jar "https://github.com/luaj/luaj/releases/download/v3.0.2/luaj-jse-3.0.2.jar"
(cd .reference && tar -xzf jdk.tar.gz)

# Then:
benchmarks/run_luaj.sh               # runs the benchmark under LuaJ
TEST_BUDGET=120 benchmarks/run_luaj.sh tests/test_sunfish.lua  # run tests under LuaJ
```

Measured on this machine (iter/s, higher is better; `ai_move` = ms per full search):

| Benchmark           | LuaJ    | LuaJIT     | Lua 5.1  |
|---------------------|---------|------------|----------|
| `new`               | 5,200   | 1,906,000  | 450,000  |
| `move (e2e4)`       | 145     | 22,700     | 3,100    |
| store/restore       | 7,200   | 443,000    | 156,000  |
| `move_2_cell`       | 68,000  | 27,500,000 | 737,000  |
| illegal `move`      | 145     | 29,000     | 2,700    |
| `ai_move` (search)  | 20.1s   | 2.8s       | 5.4s     |

LuaJ is 60–900x slower than LuaJIT depending on the operation; the string-heavy
coordinate conversion is worst (string ops are Java-call-bound), and a full
search takes ~20s vs ~3s on LuaJIT.

## Endgame correctness

`tests/test_endgames.lua` verifies the engine handles common endgames correctly:

- **Checkmate / stalemate / check detection** on classic positions
  (back-rank mate, corner mate, stalemate traps).
- **Legal move generation** matches python-chess on 40 positions
  (`tests/compare_python_chess.py`), including KQK/KRK/KPK/KNK/KBK.
- **Mate-in-1 delivery** — the engine finds and plays the mating move.
- **Stalemate avoidance** — the engine avoids stalemating traps.
- **Pawn promotion** — promotes correctly on reaching the last rank.

The engine enforces real chess rules: moves that leave the king in check are
rejected, kings are never captured, and checkmate/stalemate end the game.
`genMoves()` remains pseudo-legal for backward compatibility; `legal_moves()`,
`in_check()`, `is_checkmate()`, and `is_stalemate()` are the new public
helpers used by search and move validation.

Stockfish is used as a reference during development (see `.reference/`, not
committed); it is not required to run the tests.

## KRK / KQK endgame solver (`bkm.lua`)

`bkm.lua` (repo root) is a standalone, validated canonical KRK/KQK solver
(Bratko–Kopec–Michie-style): exact DTM in plies over the full 524288-state
graph, with `solver:best_move` for optimal mating / optimal delaying moves.
Independent oracle validation (`benchmarks/gen_bkm_oracle.py` +
`benchmarks/validate_bkm.py`) matches the full table byte-for-byte, and
`benchmarks/validate_bkm_moves.py` verifies `best_move` legality and DTM
semantics through python-chess. See `docs/endgame-question.md` for the
validation table and LuaJ/LuaJIT/lua5.1 benchmarks.

```sh
luajit benchmarks/bench_bkm.lua        # benchmark build/evaluate/best_move
python3 benchmarks/gen_bkm_oracle.py /tmp/bkm_oracle  # one-time oracle tables
python3 benchmarks/validate_bkm.py luajit /tmp/bkm_oracle      # full-table diff
python3 benchmarks/validate_bkm_moves.py luajit 4000 ... /tmp/bkm_oracle
```

## KRK / KQK lightweight mover (`bkm_light.lua`)

`bkm_light.lua` is a lightweight Bratko–Kopec–Michie-style KRK/KQK mover with
no large precomputed tables and constant tiny memory (~50 KB vs ~8 MB for the
full solver). It is the constrained-environment alternative to `bkm.lua`: it
plays legal, terminating KRK/KQK games (validated against the same oracle), but
mates are heuristic, not DTM-optimal (typically a few plies slower).

The engine can use it as a **fast path for K+R vs K / K+Q vs K**: when enabled,
`sunfish.ai_move` answers these endgames instantly without running the search.

```sh
# one-shot via env
SUNFISH_USE_BKM_LIGHT=1 luajit your_app.lua

# at runtime
sunfish.set_use_bkm_light(true)   -- returns the previous value
sunfish.set_use_bkm_light(false)  -- back to the full search (default)
```

Validation and benchmarks:

```sh
luajit benchmarks/bench_bkm_light.lua          # memory + throughput vs bkm.lua
BENCH_SCALE=0.1 benchmarks/run_luaj.sh benchmarks/bench_bkm_light_luaj.lua  # under LuaJ
python3 benchmarks/validate_bkm_light_moves.py luajit 3000 ... /tmp/bkm_oracle
luajit tests/test_bkm_light_integration.lua    # sunfish fast-path integration
luajit tests/selfplay_bkm_light.lua 150 7      # full-game stress (legal + mate)
```

The fast path uses `mate_plies = 1` (immediate mate only): a deeper forced-mate
search is ~12x slower under LuaJ and buys little over the heuristic mover.

## Notes on the engine's API (verified by the tests)

- **Rotation semantics**: the engine rotates the board after every move. `sunfish.move`
  takes coordinates in the frame of the *current* position. When it is Black's turn,
  enter the move as White would in the rotated view (e.g. after `e2e4`, Black's `e7e5`
  is entered as `e2e4` again).
- **`ai_move` returns a display move** in the rotated (Black) frame, so it will not
  necessarily replay through `sunfish.move` on the same position. It is meant to be
  shown to the user, not fed back into `move`.
- **Search must run inside a coroutine**: `search`/`bound` call `coroutine.yield()`
  periodically (every `YIELD_QUANTUM` = 256 nodes by default, tunable via
  `sunfish.set_yield(quantum, enable)`). Call `ai_move` from a coroutine (the
  test harness does this; so does the benchmark). Calling it at top level raises
  "attempt to yield across C-call boundary". Set `SUNFISH_NO_YIELD=1` in the
  benchmark to disable yields and measure uncapped throughput.
- **Global transposition table**: the TT is module-level and never cleared, so repeated
  `ai_move` calls in one process become progressively slower (measured ~0.4s, 1.1s,
  6.7s for the first three searches). The tests keep `ai_move` usage light and the
  harness gives each test a per-test budget (`TEST_BUDGET` seconds, default 30;
  raise it for LuaJ, e.g. `TEST_BUDGET=120`).
- **`sunfish.move` with non-string input** (e.g. `nil`) will raise, not return `false`.
  Only string moves are validated.
