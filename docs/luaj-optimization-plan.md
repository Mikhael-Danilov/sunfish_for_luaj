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

### Tried and reverted: LMR (late move reduction)

Implemented LMR in `bound()`: after value-sorting, moves past index 2 at
depth >= 3 are searched at depth-2 first, re-searched at full depth on
fail-high. This cut nodes ~3x (depth 5: 11,649 -> 4,112; search reached depth
6 at ~10.6k nodes vs baseline depth 5 at 11.6k) and the `move` benchmark
improved +67% (fewer move() calls per search). Tests/oracle/perft stayed green.
But alternating same-JVM LuaJ A/B showed `ai_move` was *slower*: LMR averaged
~18.4s vs baseline ~15.9s (runs: 27.9/15.6/11.8 vs 15.7/14.4/17.6). Root cause:
the reduced node count lets the search go one level deeper (depth 6), and the
larger depth-6 top tree + LMR's fail-high re-searches cost more under LuaJ's
high per-node overhead than the node reduction saves. Reverted: the node-count
win doesn't translate to LuaJ wall-clock.

### Tried and reverted: move-list preallocation

Pre-sized the per-call move lists (`genMoves`, `legal_moves`, `bound`'s filter)
to a fixed 64-entry array (MOVE_LIST_CAP) to avoid LuaJ's incremental array
growth. A microbenchmark showed preallocated list fill was ~33% faster than
growing, but in the engine it was *slower* on both targets: luajit `move`
46.3k/s -> 39.6k/s, LuaJ `move` 189/s -> 131/s, `ai_move` flat (~14.8s both).
Root cause: the engine's lists are small (~10-40 moves) so realloc cost was
already minor, while the 64-entry zero-fill + nil-clear tail adds fixed Java
calls per call under LuaJ that outweigh the savings. Also required tracking
`genMoves`'s count explicitly (the preallocated zero tail broke `#pseudo`).
Reverted: natural `{}` growth stays.

## Phase 6: post-Phase-5 review of 10 proposed optimizations

A 10-item optimization list was reviewed against the code and A/B measured under
LuaJ (same-JVM alternating harness, the reliable signal per the Phase-5 notes).
Three items shipped; two more below; the rest were rejected or deferred with
measured or reasoned justification.

### Applied: hot-path method hoisting to upvalues (SHIPPED)

Every `pos:method()` in `bound()` is a table read that misses into `__index` —
a metamethod event + function lookup (a Java call under LuaJ) — firing ~10x per
node. `bound()` now binds the nine hot methods once:

```lua
local m_genMoves = Position.genMoves
local m_king_index = Position.king_index
local m_king_sensitive = Position.king_sensitive
local m_is_legal = Position.is_legal
local m_in_check = Position.in_check
local m_key = Position.key
local m_rotate = Position.rotate
local m_value = Position.value
local m_move = Position.move
```

and calls them as plain functions (`m_genMoves(pos)`, `m_is_legal(pos, ...)`).
Pure mechanical, zero behavior change. Same-JVM LuaJ A/B: `ai_move` **-32% to
-41%** (runs: -41.5%, -3.1% noise outlier, -32.6%), identical move selection and
node count. This is the single biggest per-effort win in the review.

### Applied: 64-square iteration in genMoves (SHIPPED)

`genMoves` walked `for i = 20, 99` with an `is_on_board[i]` guard: 80 iterations,
16 of them padding. A `real_squares[1..64]` list built once at load replaced the
guard with a straight 64-iteration loop. Drops 16 wasted iterations and 80
`is_on_board` table reads per `genMoves` call. Small, safe, stacked on top of
the method hoisting in the A/B below.

### Applied: value() micro-hoists (SHIPPED)

`value()` is called per legal move per node. Hoisted `pst[p]` to a local
(`pp[j+1] - pp[i+1]`), read `self.kp` once, and replaced `math_abs(j-kp) < 2`
and `math_abs(i-j) == 2` with integer comparisons (`j-kp < 2 and kp-j < 2`,
`j-i == 2 or i-j == 2`) — verified exactly equivalent for all 0..119. Drops
library calls (Java calls) from the hottest leaf function.

### Combined A/B (items 02 + 08 + 10 vs baseline)

Same-JVM LuaJ A/B on the start position, cold, alternating order:

| Round | baseline ai_move | modified ai_move | delta |
|-------|------------------|------------------|-------|
| 1 | 15.3s | 10.4s | **-31.6%** |
| 2 | 18.2s | 8.7s | **-52.2%** |
| 3 | 17.9s | 7.6s | **-57.9%** |

Same move (`b8c6`, score 41) in every round — the delta is pure overhead
removal, not move-selection noise. Tests stay green on luajit/lua5.1 + oracle
40/40 + perft 21/21.

### Applied: king-index propagation through move()/rotate() (SHIPPED)

`king_index()` scans up to 120 squares on the first call per position; since
every search position is fresh, that's a full scan per node. But the child's
kings are known when building the rotated frame: the child's own king is the
mirror of the parent's *enemy* king (`119 - ek`), and the child's enemy king is
the mirror of the parent's *own* king (`119 - ok`, or `119 - j` when the king
moved). `move()`/`rotate()` now thread `_king`/`_eking` through the constructor,
so the hot-path `king_index()` scan is eliminated (fallback scan stays for
public positions built from strings). See "Phase 6b" notes below for the
detailed derivation.

### Applied: parallel-array transposition table (SHIPPED)

`tp_set`/`tp_get` chased a 5-field slot table and the store site built a temp
`{depth, score, gamma, move}` table per store. Replaced with five flat arrays
`ttK/ttD/ttS/ttG/ttM` indexed by `key % TT_SIZE`; `tp_set` takes the five
values directly (no temp table), `tp_get` returns nothing and the probe reads
the flat arrays + a `ttK[s] == key` verification. Removes one temp-table alloc
per store and several field chases per probe. The slots were already
pre-allocated, so the original "alloc per store" claim was overstated — the win
is the temp table + field chases, not slot allocation.

### Reviewed and rejected: comparator-free sort (item 01)

The premise was wrong: the `move_from`/`move_to` tie-decode in `sorter` fires
only when two packed integers are *identical* (requires same `i` AND same `j` —
astronomically rare). The sorter is already a raw `a > b` per comparison, so
inverting the value bias (`VAL_BIAS - val`) produces a **numerically identical
sort**. It does however *drop the `i desc, j asc` tie-break* (default sort would
give `i asc`), which changed equal-score move selection (`b8c6` -> `g8f6`) and
the node count (11649 -> 11770) in the A/B. Since the sort itself wasn't the
bottleneck (the hoisting fix addressed the real dispatch cost), the tie-break
behavior change wasn't worth it. Rejected.

### Reviewed and rejected as O(1): incremental Zobrist key (item 04)

The proposal claimed an O(1) delta from the parent's key to the child's. This is
**impossible as stated**: the child is the *mirror* of the parent, which remaps
all 120 squares (square `sq` in the child holds `-parent[119-sq]`), so the
parent's 120-square hash cannot be updated with a few delta terms — every square
contributes through a different Zobrist slot. The sound variant is to accumulate
the hash *inside* the existing single-pass `move()` board build (one 120-pass,
not two), which saves the second pass and the `key()` metatable dispatch, but it
is O(120), not O(1). Deferred — modest win, touches the highest-risk function.

### Reviewed and shipped (subset): board/Position pooling (item 05)

The full make/unmake rewrite (one mutable board, ply buffers) is still deferred,
but the *safe subset* shipped: a free-list pool of Position objects + their
120-slot boards, used by the search's `move()`/`rotate()` children.

Measured allocation profile (11,649-node start-position search, instrumented):
`move()` builds a 120-slot board 8,929x, `rotate()` 2,690x, and `from_array`
creates a Position object 11,619x — ~1 board + ~1 object per node, ~23k tables
+ ~11.6k objects per search, all short-lived garbage.

Safety argument: search children have strictly nested (LIFO) lifetimes — each is
passed to the next `bound()` frame, fully consumed there (only numbers escape:
scores, packed moves), and is dead before the next sibling is created. So a
bounded free list (POOL_CAP=1024, overflow drops to GC) is safe: a slot is only
reused after its position has fully returned. The public API (`sunfish.move`,
`ai_move`'s returned position, tests calling `rotate()`) keeps allocating fresh
via a `pooled` flag; `pool_free_pos` clears all fields so a stale reference can
never alias a live board.

Same-JVM LuaJ A/B (start position, identical `b8c6`/sc=41 every round):

| Round | baseline | pooled | delta |
|-------|----------|--------|-------|
| 1 | 17.0s | 10.7s | **-37.2%** |
| 2 | 23.1s | 19.8s | **-14.3%** |
| 3 | 16.0s | 12.3s | **-23.1%** |
| 4 | 12.3s | 14.1s | +14.7% (noise outlier) |
| 5 | 16.5s | 10.6s | **-35.5%** |

Mean ~-19% excluding the outlier; consistently negative with identical move
selection. This is the largest single win since the Phase-6 method hoisting.
Tests green on luajit/lua5.1/LuaJ (14+15+21) + oracle 40/40.

The full make/unmake rewrite (also pooling the per-node move lists) remains the
known next step for the remaining allocation, but the list-pooling attempts were
already reverted as net-slower under LuaJ (see "tried and reverted" above).

### Reviewed and shipped: yield countdown (item 07)

`nodes % 30` is a cheap integer modulo; the real cost is ~330 coroutine switches
per 10k search, each a JVM context hop under LuaJ. Replaced with a countdown
(`yield_left` decrement per node, yield every `YIELD_QUANTUM` nodes). Same-JVM
LuaJ A/B (start position, identical `b8c6`/sc=41 every round):

| Variant | Mean delta | Best round |
|---------|-----------|------------|
| countdown -> 256 | **-33%** | -55.7% |
| countdown -> 1024 | **-41%** | -57.9% |
| no yield at all | **-56%** | -77.4% |

Shipped with `YIELD_QUANTUM = 256` (tunable) and `YIELD_ENABLED`; the Android
RPD layer can lower the quantum for responsiveness or raise it for throughput,
and `sunfish.set_yield(quantum, enable)` exposes both. The benchmark harness
uses `SUNFISH_NO_YIELD=1` to measure the uncapped ceiling (no coroutine
switches).

### Reviewed and deferred: TT replacement policy (item 09)

Depth-preferred replacement (`depth + 2 >= ttD[s]`) would raise TT-hit quality
at fixed 64k slots, but changes search behavior (which entries survive) and
needs its own A/B against the same position. Deferred.

## Phases

| # | Step | Est. LuaJ gain | Risk |
|---|------|----------------|------|
| 1 | Signed-int board core + lazy sync | 2-4x | Med-High (sync invariants) | **DONE** |
| 2 | Precomputed attack/ray tables | 1.2-1.6x | Low-Med | **DONE** |
| 3 | TT: cached key + fixed-size probe table | 1.2-1.5x + bounds memory | Med | **DONE** |
| 4 | Search micro-opts (hoisted sorter, king-sensitive short-circuit) | 1.1-1.3x | Low | **DONE** |
| 5 | Hot-path call elimination (board threading, cached king, single-pass move, generation-tagged sens, flat Zobrist, TT-before-movegen) | 1.15-1.3x | Med (signature churn, in-place mutation invariants) | **DONE** |
| 6 | Phase-6 review: method hoisting, 64-square genMoves, value micro-hoists, king propagation, parallel-array TT | 1.3-2.0x cumulative on top of Phase 5 | Low-Med | **DONE** |
| 7 | Board/Position pooling (search children reuse a bounded free list) | 1.2-1.5x on top of Phase 6 | Med (LIFO lifetime invariant) | **DONE** |

Cumulative target: **~21s -> 3-5s** per `ai_move` under LuaJ.
Current: **~15.9s (Phase 1) -> ~14.2s (Phases 2-4) -> ~12.5s (Phase 5) -> ~8-11s
(Phase 6) -> ~10-11s (Phase 7 pooling)**. The move-gen and lifecycle paths are
2-3.4x faster; `ai_move` (search) gained ~27% cumulative through Phase 5, a
further ~30-55% from the Phase-6 method hoisting + 64-square + value-hoist +
king-propagation + parallel-TT batch, and ~14-37% (mean ~19%) from Phase-7
board/Position pooling (same-JVM A/B, identical move selection every round).
The remaining search time is dominated by `is_legal`'s `attacked()` walks and
per-node `move()` array construction; the full make/unmake rewrite is the known
next step but carries the documented recursion-corruption risk.

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
- The yield interval is a tunable countdown: `YIELD_QUANTUM = 256` nodes by
  default (was hardcoded at 30), configurable via `sunfish.set_yield()`;
  `SUNFISH_NO_YIELD=1` disables yields for benchmark throughput.
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
