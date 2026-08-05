# sunfish.lua — Optimization Plan for LuaJ Interpreter Mode (Android)

## Status

- [x] Phase 1: Signed-int board core + lazy sync — **DONE**
- [x] Phase 2: Precomputed attack/ray tables — **DONE**
- [x] Phase 3: TT: cached key + fixed-size probe table — **DONE**
- [x] Phase 4: Search micro-opts — **DONE**
- [x] Phase 5: Hot-path call elimination (board threading, cached king,
  single-pass `move`, generation-tagged king-sensitivity) — **DONE**

### Cumulative results (measured, BENCH_SCALE=0.01 LuaJ, interleaved runs)

| Benchmark | Phase 1 baseline | After Phase 2-4 | After Phase 5 | Delta (P1 -> P5) |
|-----------|------------------|-----------------|---------------|------------------|
| `ai_move` (full search) | ~15.9 s | ~14.2 s | ~12.5 s | **~1.27x faster** |
| `new` | 4.8k/s | 16.4k/s | 16.4k/s | 3.4x |
| `move (e2e4)` | 73.6/s | ~176/s | ~206/s | 2.8x |
| illegal `move` | 327/s | ~280/s | ~280/s | ~1x (noisy) |
| store/restore | 2.7k/s | 5.5k/s | 5.5k/s | 2.0x |

Note: LuaJ/JVM benchmark variance is high (cold-start +-30%); `ai_move` readings
ranged 13.6-18.1s across runs. A same-JVM alternating A/B (base vs Phase 5,
both cold, alternating order) is the reliable signal: Phase 5 won every round by
~15-25% (e.g. 15.1s vs 10.6s, 29.8s vs 25.1s at higher TT fill). The
`move`/`new` gains are stable and large. Tests stay green on luajit/lua5.1/LuaJ
(14 main + 15 endgame) + oracle 40/40.

### Phase 2 notes (precomputed attack/ray tables)

- `is_on_board[]`, `ray_squares[i][d]`, `knight_targets[]`, `king_targets[]`,
  `pawn_caps[]` precomputed at module load (the 0..119 geometry: cols 0/9 and
  rows 0/1,8/9 are walls).
- `genMoves` walks ray tables instead of `while` loops; castling moved into the
  rook's sliding branch (original semantics: rook at A1/H1 slides toward the
  king; `{king_sq, king_sq +/- 2}`).
- `attacked` uses target tables + 8 ray walks.
- Pawn double-push preserves the original quirk: allowed for `i >= A1+N` when the
  intermediate square is empty (a pawn on e1 can "double-push" — the oracle
  relies on this).

### Phase 3 notes (TT)

- Zobrist-style **integer key** cached on each Position (`pos._key`), computed
  once per position (not per probe). Uses a deterministic Multiply-With-Carry
  PRNG — an LCG/`rnd()*2^32+rnd()` produced terrible low-bit distribution,
  collapsing a 64k table to 2 slots (2x search slowdown). MWC gives 597/600
  distinct slots.
- Fixed-size `TT_SIZE = 65536` probe table: `key % TT_SIZE`, full key verified.
  Bounded memory (~64k slots vs the old unbounded 1e6-entry dict).
- Key covers board + wc/bc + ep + kp (NOT score), so transpositions share entries.
- ttbench (LuaJ): new set+get ~3x faster than the old string-concat dict.

### Phase 4 notes (search micro-opts)

- Hoisted `sorter` out of `bound()` (was recreated per node).
- `king_sensitive(king)`: precompute the squares that can affect king safety
  (adjacent + rays to first blocker) once per node. `is_legal` short-circuits
  moves that don't touch them or en passant — cut `attacked()` calls from
  274k to 89k per search (~3x).
- A module-level reused `moves` table was tried but caused recursion-corruption
  bugs (inner bound overwrites outer's moves; nullmove recursion corrupted the
  value loop) — reverted to per-call allocation. The TT copies the best move.

### Phase 5 notes (hot-path call elimination)

Phase 5 targets the per-node method-call overhead (each `pos:method()` is a
metatable dispatch + `ensure_arr` lookup — a Java call under LuaJ). Measured via
a call-count profile: `ensure_arr` fell from **548k to 33k** per search.
- **Board threading**: `bound()` fetches `pos._b` once and passes it as a plain
  local through `is_legal(move, king, sens, b, sens_g)`, `attacked(i, b)`,
  `king_sensitive(king, b)`, `value(move, b)`, and `move()`'s internal `value`
  call. `key()` reads `self._b` directly. Eliminates ~500k `ensure_arr()`
  method calls per search.
- **Cached king square**: `king_index()` caches `_king` on the Position. Safe
  because positions are immutable (`is_legal`'s in-place board mutations always
  undo before return, and the king square only changes on a king move). Cut
  `king_index`'s 120-scan from every `bound()` node to once per position.
- **Single-pass `move()`**: builds the *rotated* result array directly
  (sparse edits in inverted coordinates: `119-j` for the moved piece, `119-i`
  emptied, castling rook `119-A1/H1`/`119-kp`, promotion `-Q`, ep capture at
  `119-(j+S)`), replacing copy-then-rotate. The common (non-castling) case is a
  tight 2-branch loop; rare castling/promotion paths split out. Halves the
  array writes per move (240 -> 120).
- **Generation-tagged king-sensitivity**: `sens_tmp` now stores an integer
  generation per square (`sens_tmp[sq] = gen`, bumped per call) instead of
  clearing the whole table with `pairs`. `is_legal` checks `sens[i] == gen`
  (integer equality) rather than `not sens[i]` (nil test after a full clear).
- **Flat Zobrist alias**: `zflat[(pc+6)*120 + sq]` replaces the two-level
  `zob[pc][sq]` lookup in `key()` — one table get instead of two per piece.
- **TT probe moved before movegen**: a usable TT entry (same depth, bound
  satisfied) now returns before `genMoves` + the legality filter. Safe because
  a position with no legal moves never stores a TT entry (the `nlegal == 0`
  branch returns before `tp_set`), so a hit can't mask mate/stalemate.
- **Tried and reverted**: TT-move ordering (linear scan to boost `entry.move`)
  added ~235k comparisons and no node reduction — net loss. Incremental
  Zobrist keying across `rotate()` is not feasible (the rotate re-maps every
  square), so `key()` stays a per-position cached 120-slot hash.
- **Validation catch**: the single-pass `move()` castling branch initially
  wrote the rook as `R` (own color) instead of `-R` (rotated frame negates
  colors) — caught by a dedicated castling/promotion/en-passant board check
  against the reference semantics. Fixed and covered by the oracle + tests.
  No existing test exercised castling, so a standalone check was used.

## Problem

The engine's 120-char string board is catastrophic under LuaJ's interpreted VM
(no luajc/bcel on Android). Every square read is `string.sub` (a Java call +
object alloc), `rotate()` does `string.reverse` + full-board `gsub`, `is_legal`
rebuilds the board 2-4x per move via string concat, and the TT hashes the whole
120-char board twice per node.

Measured (LuaJ vs LuaJIT): `move_2_cell`/`cell_2_move` ~900x slower,
`move` ~230x, `ai_move` ~21s vs 3s.

## Approach: integer-board core, string only at API boundaries

Keep `board` as a string for backward compatibility, but make it a **lazy view**
over a 120-element integer array `_b` that the hot path uses:

- **Piece codes**: `0=empty, 1..6 = our pieces (PNBRQK), -1..-6 = enemy,
  98='\n' padding, 99=' ' padding`. Same 0-119 indexing (A1=91 etc. intact).
- **`ensure_arr` / `ensure_board`**: `Position` lazily builds `_b` from the
  string on first use, and materializes `board` only at public boundaries
  (`sunfish.move` success, `ai_move` both paths, `store_data`). Internal search
  positions carry no string.
- **`rotate()`**: one 120-pass over `_b` (`nb[k] = (v>=98) and v or -v` for
  `v = b[119-k]`) — no `string_reverse`/`gsub`.
- **`move()`**: builds the rotated result array in a single pass, applying the
  sparse edits in inverted coordinates (no copy-then-rotate).
- **`is_legal`**: mutate `_b` in place, test, undo — no board copy, no temp
  Position.
- **`genMoves` / `attacked`**: int comparisons replace string lookups.
- **Packed moves** (post-Phase-5): `genMoves` emits a single integer per
  pseudo-legal move (`i*128 + j + (val+2^22)*2^14`) instead of a `{i, j, val}`
  table — one allocation per move becomes zero, and a packed int has value
  semantics so the Phase-4 recursion-corruption risk (aliased shared table)
  can't recur. `move_from`/`move_to`/`move_val` are pure arithmetic; LuaJ
  **does** ship `bit32`, but a direct A/B on LuaJ 3.0.2 showed arithmetic
  unpack (`math.floor`/`%`) is ~2x faster than `bit32.band`/`rshift` for the
  dominant `i`/`j` decode (bit32 is heavier Java calls here), so the packing
  stays arithmetic (also keeps luajit/lua5.1 compat). `Position:move`/`value`
  accept both packed ints (internal search) and `{i, j}` tuples (public API).
  Measured same-JVM LuaJ A/B: `move` 188→256/s (+36%), `ai_move` 18.5s→~12-14s
  (~1.3-1.5x). Tests stay green on luajit/lua5.1/LuaJ + oracle 40/40.

### Tried and reverted: scratch-pooled move lists

Reusing a per-depth scratch list for `genMoves`/`bound`'s filter (moves are
packed ints now, so no aliasing risk) was tested to remove the per-node list
allocation. It introduced a subtle stale-tail bug (`table_sort` sorts the
whole reused table, pulling stale entries from a previous frame at the same
depth into the legal list — caught by the KRK mate-in-1 endgame), and the fix
(stale-tail clearing + `#moves`) added enough overhead that same-JVM LuaJ A/B
showed it was *slower* than the fresh-list baseline (`move` 326/s baseline vs
210/s pooled, `ai_move` 13.5s vs 14.5s). Reverted: per-node fresh lists stay.

### Perft harness (`tests/test_perft.lua`)

Added a perft suite (recursive legal-move counting vs reference counts) with a
FEN -> engine-position builder that handles the engine's frame convention
(side to move uppercase at the bottom; castling rights stored in `wc` for the
side to move, `bc` for the opponent; ep square mirrored for black to move).
21 checks: the start position (20/400/8902/197281), two castling positions
(kiwipete d1-d2, r4rk1 d1-d3), pos5 (31/771/24204), pos3 d1-d3, pos4 d1, and
8 documented-deviation checks. This confirmed the core move generation is
correct and quantified the three known sunfish-faithful deviations from
standard chess:
  * **1st-rank double-push** (pos3 d5 over-counts: pawn on e1 can double-push).
  * **auto-queen promotion** (pos4 under-counts: one move instead of 4 choices).
  * **kiwipete d3 castling/ep interaction** (small -80 difference).
Runs green on luajit/lua5.1/LuaJ (21/21). The FEN builder doubles as a
correctness cross-check for future search changes.

### Tried and reverted: flat attack tables

Profiling showed `attacked()` (24µs/call on LuaJ, 290k calls/search) and
`is_legal` (13.5µs, 937k calls) dominate search: `is_legal`+`attacked`+`genMoves`
≈ 54% of LuaJ time. A flat-table redesign replaced the nested
`ray_squares[i][di]` (two table gets per ray per square) with per-square flat
arrays (`attack_rook`/`attack_bishop`/`attack_queen`) delimited by `RAIL_END`
(per-rail stop) / `RAIL_STOP` (array end), plus an `on_board_squares` list for
genMoves and a `pack_base` emission shortcut. Correctness held (14+15 tests +
oracle 40/40 on luajit/lua5.1), but same-JVM LuaJ A/B showed it was *slower*:
`ai_move` 17.2s vs 16.3s baseline, `move` 164/s vs 183/s. The per-square
`RAIL_END`/`RAIL_STOP` branch adds a Java call per cell under LuaJ that offsets
the saved table-get. Reverted: nested `ray_squares[i][di]` stays. The flat
concept only wins if the walker can avoid a per-cell branch (e.g. sentinel-free
or bitmask attack boards), which is a larger Phase-6-scale redesign.

## Phases

| # | Step | Est. LuaJ gain | Risk |
|---|------|----------------|------|
| 1 | Signed-int board core + lazy sync | 2-4x | Med-High (sync invariants) | **DONE** |
| 2 | Precomputed attack/ray tables | 1.2-1.6x | Low-Med | **DONE** |
| 3 | TT: cached key + fixed-size probe table | 1.2-1.5x + bounds memory | Med | **DONE** |
| 4 | Search micro-opts (hoisted sorter, king-sensitive short-circuit) | 1.1-1.3x | Low | **DONE** |
| 5 | Hot-path call elimination (board threading, cached king, single-pass move, generation-tagged sens, flat Zobrist, TT-before-movegen) | 1.15-1.3x | Med (signature churn, in-place mutation invariants) | **DONE** |

Cumulative target: **~21s -> 3-5s** per `ai_move` under LuaJ.
Current: **~15.9s (Phase 1) -> ~14.2s (Phases 2-4) -> ~12.5s (Phase 5)**. The
move-gen and lifecycle paths are 2-3.4x faster; `ai_move` (search) gained ~27%
cumulative (Phase 4 +12%, Phase 5 +15-25% in same-JVM A/B). The remaining
search time is dominated by `is_legal`'s `attacked()` walks and per-node
`move()` array construction, which are hard to reduce without deeper search
restructuring (packed move arrays were considered but carry the documented
recursion-corruption risk for modest gain).

## Validation per phase

- `luajit` + `lua5.1` run `tests/test_sunfish.lua` (14) and
  `tests/test_endgames.lua` (15) — all green.
- `python3 tests/compare_python_chess.py` — 40/40 legal-move oracle.
- `TEST_BUDGET=120 benchmarks/run_luaj.sh tests/test_sunfish.lua` under LuaJ.
- `BENCH_SCALE=0.01 benchmarks/run_luaj.sh` — record `ai_move` ms / `move` iter/s.

## Android specifics

- Pure Lua 5.1 source: no luajc, no bcel, no bit32, no FFI.
- Fixed-size TT (`TT_SIZE = 65536`) replaces the unbounded string-keyed dict
  (`TABLE_SIZE = 1e6` was removed) -> bounded ~10MB. `TT_SIZE` is now a tunable
  constant; `NODES_SEARCHED` remains the exposed tunable.
- The yield interval is still hardcoded at every 30 nodes (`nodes % 30`).
- Search `print` is still unconditional (no `SUNFISH_VERBOSE` gate yet).

## Key risks (covered by existing tests)

- `board` nil on internal positions -> `ensure_board` at every public return.
- `store_data` round-trip -> materialize `board` first, filter `_`-prefixed fields.
- `is_legal` in-place undo (highest-risk) -> oracle + tests.
- `rotate()` `119-ep`/`119-kp`/case-swap semantics preserved.
- TT slot only selects the bucket; the stored full `_key` is verified on probe
  (`slot.key == key`) -> no wrong entries, collisions only cost a missed lookup.
- `king_sensitive` short-circuit must not misclassify: only skips `attacked()`
  for moves that provably can't change king safety (verified by oracle 40/40).
