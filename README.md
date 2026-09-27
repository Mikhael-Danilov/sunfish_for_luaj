# sunfish.lua — tests & benchmarks

Zero-dependency test suite and benchmarks for the chess engine in `sunfish.lua`,
covering its public API only:

- `sunfish.new()` — fresh starting position
- `sunfish.move(game, mv)` — apply a legal move (returns the next position, or `false`)
- `sunfish.ai_move(game, black_to_move)` — engine search (returns position, move string, score). The second argument is optional: callers that KNOW the side to move pass it (`true` = black), which keeps the opening book alive for AI replies — the positional side-scan fallback breaks on advanced pawns crossing the midline.
- `sunfish.store_data(game)` / `sunfish.restore_data(data)` — serialize/deserialize a position
- `sunfish.move_2_cell(i)` / `sunfish.cell_2_move(cell)` — square index <-> coordinate
- `sunfish.MATE_VALUE`
- `sunfish.set_book(path, seed)` / `sunfish.set_book_data(tbl, seed)` — opening book from a binary file / a pre-parsed Lua table (the table form is for platforms like Android where `io.open` cannot read APK assets)
- `sunfish.set_yield(quantum, enable)`, `sunfish.set_nodes(n)`, `sunfish.set_futility(m)`, `sunfish.set_time_budget(s)`, `sunfish.set_use_bkm_light(b)` — runtime tunables

## Yield substrate: fiber (our LuaJ fork) vs coroutine

The search yields periodically so the caller can poll. The engine picks the
mechanism at load:

- **`fiber.yield`** — the [NYRDS/luaj](https://github.com/NYRDS/luaj) fork's
  zero-thread fiber library (heap-allocated frames, no JVM thread parked per
  switch). Default quantum 32. The search must be driven from `fiber.create`.
- **`coroutine.yield`** — stock LuaJ and the PUC-Lua family. Default quantum
  256 (each yield is a JVM context hop under LuaJ; bigger quantum measured
  ~33-41% faster).

All tests and benchmarks drive the search through `green.lua` (`green.run(fn)` /
`green.guard(fn, poll)`), which picks the same facility the engine picked, so
the same script runs unchanged on luajit, lua5.1, stock LuaJ, and the fork.

Measured CPU time (8 start-position searches per cold JVM, `/usr/bin/time`
User time, fork jar, coroutine substrate vs fiber substrate, alternating):

| substrate            | mean user time |
|----------------------|----------------|
| fork + coroutine 256 | 2.22 s         |
| fork + fiber q32     | 3.34 s         |
| stock 3.0.2 + coroutine 256 | 2.71 s  |

Notes: the fiber *substrate* (FiberVM trampoline executing the whole search)
costs ~40-50% CPU over the recursive `LuaClosure.execute` path even with
yields disabled — what fiber buys is zero-thread switching (no thread park per
yield, tiny quanta for free), which is why the Android embedding uses it. The
fork's non-fiber fixes (LuaTable/weak-table/metamethod) are a ~20% win over
stock 3.0.2. On PUC Lua/luajit, coroutine is the only (and fine) choice.

## Requirements

- Lua 5.1+ or LuaJIT (both tested). No external dependencies.
- For the cross-validation test (`tests/compare_python_chess.py`): Python 3
  with `python-chess` installed (`pip install python-chess`).
- For the LuaJ runs: a JDK and a luaj jar (below).
- For the Elo harness / selfplay gates: a Stockfish binary (SF 17.1 validated;
  the SF 19 "universal" build segfaulted mid-session on this machine).

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
interpreters; the LuaJ wrapper defaults to 0.01. For repeated-search CPU-time
A/Bs (the reliable signal — single cold searches are JIT-warmup noise):

```sh
AI_ITERS=8 /usr/bin/time -f "%U" java -Dluaj.path="$PWD/?.lua;$PWD/tests/?.lua" \
    -cp .reference:.reference/luaj-fork-jse.jar LuajRun benchmarks/bench_ai.lua 8
```

## LuaJ (Java) benchmarks

LuaJ is the Java-based Lua interpreter (luaj.org / `luaj/luaj` on GitHub),
not LuaJIT. The engine was tuned for "Luaj interpreter mode", so run the
benchmarks under it:

```sh
# One-time setup: put a luaj jar under .reference/ (gitignored).
# Fork (fiber-capable; built from the NYRDS/luaj submodule) and/or stock 3.0.2:
cp <path-to-fork>/luaj/build/libs/luaj-jse-3.0.2.jar .reference/luaj-fork-jse.jar
curl -sL -o .reference/luaj-jse-3.0.2.jar \
  "https://github.com/luaj/luaj/releases/download/v3.0.2/luaj-jse-3.0.2.jar"

# Then (any JDK 8+; JAVA_HOME or java on PATH):
benchmarks/run_luaj.sh               # runs the benchmark under LuaJ
LUAJ_JAR=.reference/luaj-stock-3.0.2.jar benchmarks/run_luaj.sh   # stock jar
TEST_BUDGET=120 benchmarks/run_luaj.sh tests/test_sunfish.lua     # tests under LuaJ
```

`run_luaj.sh` compiles `benchmarks/java/LuajRun.java` (committed) into
`.reference/` on first use. The launcher installs the fork's `FiberLib` when
the jar provides it (exactly like the Android embedding does) and skips it
with `-Dluaj.nofiber=true`; on the stock jar it runs on coroutines.

Measured on this machine (i9-12900K, iter/s, higher is better; `ai_move` =
single cold search):

| Benchmark           | LuaJ    | LuaJIT     | Lua 5.1  |
|---------------------|---------|------------|----------|
| `new`               | 250,000 | 1,520,000  | —        |
| `move (e2e4)`       | 4,348   | 82,600     | —        |
| `ai_move` (search)  | 0.112s  | 0.008s     | —        |

LuaJ stays ~14x slower than LuaJIT per search (same ratio as the original
1 GB-VM measurements; the absolute numbers differ because that box was
load-contaminated — see the measurement caveat in
`docs/luaj-optimization-plan.md`).

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
rejected, **castling out of check is rejected** (fixed 2026-09-26 — the old
castling legality path only tested the between/landing squares, which a king
escaping a check ray could pass), kings are never captured, and
checkmate/stalemate end the game.
`genMoves()` remains pseudo-legal for backward compatibility; `legal_moves()`,
`in_check()`, `is_checkmate()`, and `is_stalemate()` are the new public
helpers used by search and move validation.

Promotions: the search generates and values all four promotion pieces
(queen-valued highest for ordering) and the display move carries the promoted
piece char (5 chars, e.g. `f2f1n`) — under-promotions are real search
choices, and every harness/bridge now propagates the char instead of
coercing to queen.

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
**Default ON since 2026-09-26** — the bare search converts only ~46% of KRK/KQK
games within 100 plies (the 20+ ply mating nets live far outside its horizon);
the fast path converts ~97% at constant tiny memory and zero search cost. The
fast path fires only on the exact K+R/K+Q vs K material signature and returns
score 0 (it performs no search). Its display move follows the same rotated-frame
convention as the search path.

```sh
# opt out via env
SUNFISH_USE_BKM_LIGHT=0 luajit your_app.lua

# at runtime
sunfish.set_use_bkm_light(true)   -- returns the previous value
sunfish.set_use_bkm_light(false)  -- back to the full search
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
  shown to the user, not fed back into `move`. Callers that know the side to move
  should pass `black_to_move` — book replies then come out in the correct frame even
  when the positional side-scan would misfire.
- **Search must run inside a green thread**: `search`/`bound` yield periodically
  (fiber on the fork, coroutine elsewhere; every `YIELD_QUANTUM` nodes, tunable via
  `sunfish.set_yield(quantum, enable)`). Drive it with `green.run(fn)` (or
  `green.guard(fn, poll)` for budgeted tests). Calling `ai_move` at top level raises
  "attempt to yield across C-call boundary". Set `SUNFISH_NO_YIELD=1` in the
  benchmark to disable yields and measure uncapped throughput.
- **Global transposition table**: the TT is module-level and never cleared, so repeated
  `ai_move` calls in one process become progressively slower. The tests keep `ai_move`
  usage light and the harness gives each test a per-test budget (`TEST_BUDGET` seconds,
  default 30; raise it for LuaJ, e.g. `TEST_BUDGET=120`).
- **`sunfish.move` with non-string input** (e.g. `nil`) will raise, not return `false`.
  Only string moves are validated.
- **Opening book (opt-in)**: `sunfish.set_book(path, seed)` loads a binary book of
  16-byte entries (position Zobrist key -> weighted moves); `sunfish.set_book_data(tbl, seed)`
  loads the same shape pre-parsed into a Lua table (Android assets). Pass `nil` to disable.
  Once loaded, `ai_move` plays a weighted-random book move when the position's key is
  in the book, falling through to the search otherwise. The shipped book is
  `benchmarks/sunfish.bin` (~25 kB), generated from Stockfish MultiPV lines + classic
  trap lines by `benchmarks/gen_book.py`; it does NOT cover black replies to 1.e4
  (the `test_book` black-reply test exercises the search fallback, not the book).
- **Futility pruning**: `SUNFISH_FUTILITY=<margin>` (or `sunfish.set_futility(m)`,
  0 = off) tunes frontier pruning at depth 1 on interior nodes. Default 200;
  strength-neutral within the Elo noise band at 128 games, positive direction.
- **Ordering heuristics (2026-09-26)**: history (cutoff moves gain depth*depth,
  capped under the 150 quiet/capture line) + two killers per ply + TT-move-first,
  all folded into the sort key only (bonuses are subtracted back out before the
  value threads into the child's material score). Bonus identities are compared
  coordinate-only so stored sort values can never leak through the persistent TT.
- **LMR (2026-09-26, third attempt — SHIPPED)**: late quiet moves (after index 3,
  depth >= 3, not in check, > 6 pieces) search one level shallower first and
  re-search at full depth on improvement. The two earlier rejections were caused
  by PST-only ordering; with history/killers landed, LMR is CPU-neutral-to-faster
  and gate-clean. `SUNFISH_LMR=0` disables.
- **Budget-abort hygiene (2026-09-26)**: a node-budget abort mid-probe no longer
  clobbers the last completed depth's root result (the truncated probe's junk
  return used to poison the MTD binary search), and aborted unwinds no longer
  store junk into the persistent TT.
- **Endgame leaf (2026-09-26)**: the king-corraling gradient at sparse leaves is
  now capture-aware — when a tactical shot (capture/promotion) exists, the leaf
  searches instead of returning the gradient (a hung heavy piece used to be
  invisible at the horizon: lone-king-takes-queen draws).
- **Search robustness batch (2026-09-26, round 3)**:
  - *Null-move guards*: the probe requires depth >= 3 (a shallow null probe
    reads a qsearch repetition draw as a proven cutoff and feeds MTD a phantom
    score — observed as a 1000-node depth-1 burn returning nil), is skipped
    while in check, and in sparse positions (<= 6 pieces, zugzwang territory —
    same line as the futility/LMR guards; `SUNFISH_NULL_ENDGAME=1` restores the
    unguarded endgame probe).
  - *Check extension*: in-check interior nodes (depth >= 2, ply < 32) search
    their evasions one ply deeper. `SUNFISH_CHECK_EXT=0` disables.
  - *Qsearch check evasions*: at depth <= 0 while in check the leaf searches
    ALL legal moves (capture-only "evasions" miss quiet king escapes — a mated
    leaf read as a fine stand-pat), down to depth >= -4, with the stand-pat
    rescue and corraling gradient disabled there. `SUNFISH_QEVASIONS=0`
    disables.
  - *MTD(f) root walk*: root probes target the current best estimate instead
    of the window midpoint (zero-window probes cut fast). Where bisection
    thrashed (1020 nodes to converge depth 1 on an Italian middlegame), the
    walk converges in 298; Elo-neutral overall, more wins at the 1000-node
    budget. `SUNFISH_MTDF=0` reverts to bisection; `SUNFISH_ASP=<n>` retunes
    the aspiration window (default 100, measured outcome-neutral).
  - *Endgame king-activity leaf term*: at 5..8-piece leaves the stand-pat score
    gains a small king-centralization bonus (the threaded PST's king table
    rewards corner safety — a middlegame concern). A pure leaf term, NOT a PST
    swap: threading phase-dependent deltas would make transpositions'
    scores depend on their move-order history.
- **Measured (round 3)**: full-battery gates green (suites luajit/lua5.1/LuaJ,
  perft 21/21, oracle 40/40, selfplay both colors SF-validated 0 failures,
  python-chess cross-validation 40/40, KQK/KRK conversion 389/400 = 97.2% with
  0 draws, defense 200/200). Elo vs SF18 (256 games, seed 1 + seed 2): fitted
  1942 both — equal to the round-2 baseline at measurable precision, with the
  loss count at 30000 nodes down from 16/32 to 2-6/32 (draws absorbed the
  difference). CPU per search ~154-160 ms (fork jar, 8-search steady mean) —
  neutral-to-slightly-better than round 2's 166 ms. Tried and rejected as
  Elo-neutral: extended futility at depth 2, TT depth-preferred replacement,
  qsearch first-ply checks (+12% CPU for nothing), adaptive null reduction.
- **Round 4 (2026-09-27) — qsearch node efficiency + LuaJ CPU batch**: three
  search features (`SUNFISH_CM`/`SUNFISH_QDELTA`/`SUNFISH_COQ` knobs, all
  default ON) and three CPU optimizations. *Countermove ordering* (refutations
  keyed by the opponent's previous move), *qsearch delta pruning* (hopeless
  captures skipped when stand-pat + gain + margin can't reach gamma), and
  *capture-only leaf generation* (not-in-check qsearch leaves skip quiet
  emission/filter/value entirely; a zero-capture leaf regenerates once to tell
  stalemate from stand-pat). CPU optimizations: flat 1-D PST reads in
  `value()`, the ordering-bonus array sorted in parallel with the moves (also
  fixes a latent bonus-isolation hole — the old reconstruction re-read history
  after descendants could have updated it), and sparse pooled boards (padding
  template + zero-real-squares-on-free; `move()`/`rotate()` write only the
  ~32 occupied squares instead of a 120-cell copy). **Measured, fork jar,
  1000-node budget: 162 -> 128 ms on the standard bench (-21%), 118 -> 77 ms
  startpos (-35%), 160 -> 75 ms tactical middlegame (-53%).** Elo at the SAME
  node budget is neutral (1963/2012 base vs 1953-1985 variants, ±50 noise
  band); the strength shows at a fixed WALL budget, where the engine now
  affords ~1.4-2x nodes. KQK/KRK conversion improved to **395/400 = 98.8%**
  (0 draws), draw-holding 200/200, all gates green (see
  `docs/luaj-optimization-plan.md` round 4).
- **Under-promotions**: `ai_move` may return a 5-char move (`e7e8n`) — carry the
  promo char through your display/UCI conversion; coercing to queen desyncs the
  engine state.
