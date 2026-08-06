# sunfish.lua — Optimization Plan for LuaJ Interpreter Mode (Android)

## Status

- [x] Phase 1: Signed-int board core + lazy sync — **DONE**
- [x] Phase 2: Precomputed attack/ray tables — **DONE**
- [x] Phase 3: TT: cached key + fixed-size probe table — **DONE**
- [x] Phase 4: Search micro-opts — **DONE**
- [x] Phase 5: Hot-path call elimination (board threading, cached king,
  single-pass `move`, generation-tagged king-sensitivity) — **DONE**
- [x] Phase 9: Full 1-based indexing + sentinel-terminated rays — **DONE**
- [x] Phase 10: Behavior-identical batch (leaf filter-before-sort, TT pre-size,
  micro batch, `sunfish.move` one-move legality) — **DONE**; item 2
  (dual-hash Zobrist) reverted — exposed a pre-existing `is_legal` en-passant
  undo bug (see the Phase-10 section)
- [x] En-passant undo bug: **root-caused and fixed** — `rotate()` (null-move
  child) mirrored a stale `ep`, producing bogus ep captures + board corruption;
  `rotate()` now clears `ep` and `is_legal` verifies `b[j+S] == -P`. Genuine ep
  still works; suites green. Search now reaches depth 6 (~15.8k nodes) — see
  "En-passant undo bug" note below.
- [x] Item 2 (dual-hash incremental Zobrist): **re-shipped after the ep fix** —
  now behavior-identical (invariant 27/197/411/1818/4036/15803, `a8b6`); A/B
  won 4 of 5 rounds (mean ~-7%); O(1) `key()` for search children. See the
  Phase-10 section. **⚠️ REBENCH — wall-clock-based, within CPU noise.**
- [x] A+B+C+D cleanup batch: behavior-identical; **~13% CPU-time win** (base
  13.29s vs mod 11.48s mean `User time`) — confirmed with OS-level CPU timing,
  not wall-clock. See the post-item-2 review.

> **Measurement caveat**: all numbers before the CPU-time correction used LuaJ
> `os.clock()` = `System.currentTimeMillis()` (wall-clock, verified in the OsLib
> bytecode) or `/usr/bin/time` wall — both load-contaminated on this VM. The
> reliable signal is `/usr/bin/time -v` `User time` (CPU). Phase-6/7/8/9 and
> Phase-10 percentages are wall-clock-based and **not yet re-verified**; item 2
> and the Phase-10 A/B table carry explicit rebench markers.

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

> **⚠️ REBENCH — wall-clock contaminated.** The Phase-6/7/8 A/B tables below
> used LuaJ's `os.clock()` (wall-clock, `System.currentTimeMillis()`-based).
> The percentages are load-affected on this VM and are **directional, not
> authoritative** — the qualitative wins (pooling, pooled move buffers, sorted
> generation) are real, but the exact deltas need CPU-time re-measurement
> (`/usr/bin/time -v` `User time`) in a clean session.

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

### Reviewed and shipped: pooled move buffers + count-driven sort

The remaining per-node allocation was the two move-list tables (`genMoves`'
pseudo list + `bound`'s filter list, ~0.93/node each). The earlier "scratch-
pooled move lists" attempt was reverted because it relied on `#` (LuaJ's
`rawlen` is a binary search over the array part) + a stale-tail clear, whose
bookkeeping added more Java calls than the saved allocations. The re-test
avoids both:

- `genMoves(out, start)` writes packed moves into a caller-provided array and
  returns the end index (public `legal_moves` still passes a fresh table).
- `bound()` uses a **per-ply `move_stack`** (indexed by recursion depth), so
  each frame has its own buffer — a single shared buffer is *not* safe because
  the recursion overwrites it while the outer frame still iterates its sorted
  moves (measured live: shared buffer exploded the search to 97k nodes with a
  wrong move before the per-ply fix).
- Filtering compacts in place (`nlegal <= k`, so compaction never overwrites an
  unread entry); the explicit count makes `#` and tail-clearing unnecessary.
- A count-driven **min-heap `move_sort`** replaces `table.sort` + the Lua
  comparator on the search path (max-heap + extract-to-end would produce
  ascending; the min-heap yields descending = best-first). Verified byte-
  identical ordering to the old `sorter` on randomized inputs.

Search output is byte-identical to baseline (11,649 nodes, `b8c6`, sc=41).
Same-JVM LuaJ A/B (start position, identical move/score every round):

| Round | baseline | pooled-moves | delta |
|-------|----------|--------------|-------|
| 1 | 23.0s | 11.3s | **-51.0%** |
| 2 | 16.5s | 11.9s | **-27.6%** |
| 3 | 14.5s | 11.5s | **-20.9%** |

Mean ~-33%. This is the largest win of any Phase-6/7 item and directly
contradicts the old reversion: eliminating the list tables AND the Java-side
`table.sort` heap dwarfs the `LuaInteger` per-entry churn. Tests green on
luajit/lua5.1/LuaJ (14+15+21) + oracle 40/40.

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

## Phase 9: full 1-based indexing + sentinel-terminated rays (SHIPPED)

Under LuaJ's `LuaTable`, integer keys only hit the fast `LuaValue[] array` part
when `1 <= key <= array.length`; `0`/negative keys fall to `hashget` (boxed
`LuaInteger` + `hashmod` + `Slot` chain). The engine was 0-based everywhere, so
`_b[0]`, `ttK[0]`, `zflat[0]`, `ray_squares[0]` all lived in the hash part.

An earlier "tables1" experiment shifted *only the table keys* to 1-based while
keeping 0-based square *values*, which forced a `±1` conversion on every hot
access (`b[i+1]`, `move_pack(i-1, j-1)`, `120-k+1` in the 120-pass builds) and
was **~18% slower** than baseline. The clean fix is a **full 1-based
convention**: squares, packed moves, constants (`A1=92, H1=99, A8=22, H8=29`),
and mirrors (`121 - x`) all shift together, so the hot path has **zero
conversion arithmetic** — the only `+1`/`-1` is at the public `parse`/`render`/
`cell_2_move` boundary.

Implementation notes (the pitfalls that made the earlier attempt fail):
- **Mirror is `121 - x`, not `120 - x`**: 1-based square `s` mirrors to
  `121 - s` (0-based `s-1` mirrors to `119-(s-1)` = `120-s`, then +1 = `121-s`).
  An initial `120 - x` bug mirrored e4 to d5 (off by one) and corrupted the
  board (the "reproduces parent board" / ep-undo-leak symptoms).
- **`zob_ep`/`zob_kp` need a sentinel at `121`**: `121 - 0` (mirror of the
  "no ep/kp" 0 sentinel) must be a valid table key or `key()` crashes.
- **`pst` indexing drops the `+1`**: `pst[p][j+1]` (0-based) becomes
  `pst[p][j]` (1-based); the castling between-square and `A1`/`H1` offsets drop
  too. Missed this and the search picked a wrong move at equal score.
- **`real_squares`/ray tables store 1-based squares; `is_on_board` stays the
  0-based predicate** for the precompute's geometry, plus a `is_on_board_1`
  for `genMoves`' 1-based `j` checks.
- **Search output**: depth-by-depth node counts and scores match baseline
  (27/258/755/4156/11653 nodes, depth-5 score 41); only the equal-score
  tie-break pick can differ (`a8b6` vs `b8c6`) because the packed-int ordering
  shifts with the +1 encoding — acceptable, both are valid score-41 moves.

Stacked on top: **sentinel-terminated ray arrays** (trailing `0` in each
`ray_squares[i][di]`, walked with `while true` in `attacked()`/`genMoves`),
replacing the `#ray` bound in the two hottest walkers. LuaJ's `rawlen` is fast,
but dropping the per-cell `LEN` + two-level `ray_squares[i][di]` decode in the
attack walk still helps the movegen-heavy `move` path.

Same-JVM LuaJ A/B (identical move/score, cold, alternating):

| Variant | `ai_move` rounds | `move` (iter/s) |
|---------|------------------|-----------------|
| baseline (0-based) | ~24-32s | ~206 |
| full1 (1-based) | ~17-21s (**-20-40%**) | ~436 (**+2.1x**) |
| full1 + sentinel rays | ~16-20s (≈ full1, noisy) | ~585 (**+2.8x**) |

The `ai_move` (search) win is ~20-40% consistently; the `move`/movegen path
roughly doubles and the sentinel rays add another ~+34% on top. Tests green on
luajit/lua5.1/LuaJ (14+15+21) + oracle 40/40 (oracle `render` decode updated
for the 1-based packed moves).

## Post-Phase-9 review: TT probe/store inlining + flattened rays (NOT SHIPPED)

Two follow-ups from the original suggestion list were A/B'd on top of Phase 9:

- **Inline TT probe/store in `bound()`**: replace `tp_get`/`tp_set` calls with
  the flat-array reads (`ttK[ts] == key` guard, `ttS[ts]`/`ttD[ts]`, and direct
  writes at the store site), reusing the computed slot `ts = key % TT_SIZE + 1`
  for the bound-check instead of recomputing `%`.
- **Flattened ray walks**: build `ray1..ray8` per-direction aliases
  (`rayN[sq] == ray_squares[sq][N]`) and rewrite `attacked()`'s two nested-di
  loops into 8 direct sentinel walks, turning `ray_squares[i][di]` (two table
  gets) into `rayN[i]` (one).

Both are pure overhead removal: identical move selection, node counts, and
score (11653 nodes, `a8b6`, 41) vs the Phase-9 baseline; all tests green
(14+15+21) + oracle 40/40.

**Microbenchmark signal (`move`, BENCH_SCALE=0.05 LuaJ)**: clearly faster on the
movegen path — ttinline ~450-650/s and flatray ~390-480/s vs baseline
~270-575/s (noisy but ttinline consistently at the top).

**Self-play signal (primary benchmark)**: a new `benchmarks`-style harness
drives `ai_move` for both sides (the engine rotates, so one engine plays both
colors), derives each actual chess move by un-rotating the child board and
diffing, and logs per-ply move/score/ms. Paired, same-game runs (the two
engines produce byte-identical move sequences) give a **mixed result**:

| Protocol | Combined (ttinline+flatray) vs baseline |
|----------|------------------------------------------|
| 40-ply, 2 pairs | -12.9s, -12.9s (combined faster) |
| 20-ply, 3 pairs | -2865, +2098, +1158 ms |
| 16-ply, 5 pairs | -1269, +2409, +5841, +78, -407 ms |

**Verdict: not shipped.** The self-play timing is within LuaJ's ±30% variance —
combined won some pairs and lost others by similar margins, and the largest
single swing went against it. The `move` microbenchmark overstates the win
because it isolates one hot loop; real self-play is dominated by the ~11k-node
iterative-deepening search per move, where saving a couple of `CALL`/table-get
per node is lost in the noise. The known next step for search speed remains the
make/unmake rewrite (cutting `is_legal`'s `attacked()` cost).

Self-play harness notes: `ai_move` occasionally returns `nil` at the root (the
module-level TT's root entry is overwritten by a deeper transposition), which
the engine handles by passing (board unchanged); the harness reports `(pass)`
and continues.

## Post-Phase-9 review: 7-item optimization proposal (reviewed, not implemented)

A 7-item proposal for the next round was reviewed against the current code and
the phase history. All code-level claims in the proposal were verified against
the source; the verdicts below reflect the plan's established measurement
discipline (same-JVM A/B for behavior-identical items, oracle+perft+endgames
for node-count-changing item 1, self-play medians for shipping decisions).

### Verified code-level observations (all confirmed)

- **Item 7 single-modulo probe**: `bound()` recomputes `key % TT_SIZE + 1`
  twice (lines 1214-1215) after `tp_get` already computed it (line 1077).
  Real dead work; identical to the not-shipped ttinline's finding.
- **Item 3 double `move_val(move)` decode**: line 1269 decodes the packed move,
  line 1272 decodes the *same* move again. Also, line 1269's `move_val()` call
  is evaluated even when `depth > 0` (the `and` short-circuits the `< 150`
  compare, not the function call).
- **Item 4 `2 ^ VAL_SHIFT` / `128 * 128` re-evaluated**: `2^14` is recomputed on
  every `move_pack`/`move_val`/`move_set_val` call (Lua 5.1 has no constant
  folding), and `128*128` on every `move_set_val`. Hoisting to precomputed
  locals is valid and free.
- **Item 3 leaf-break claim**: the sorted loop breaks at the first
  `move_val < 150` (line 1269-1271), so the tail is never searched. Filtering
  by value before sorting is behavior-identical.
- **Item 5 TT arrays start empty**: `ttK/ttD/ttS/ttG/ttM` are declared as
  empty `{}` (lines 1060-1064), so the first search pays several rehashes
  filling up to 64k integer keys. Pre-sizing at load is valid.
- **Item 1 remaining `attacked()` calls**: the `king_sensitive` short-circuit
  (lines 760-770) already skips `attacked()` for most non-king moves. The
  remaining calls are king moves, en-passant, moves touching sensitive
  squares, and `king_sensitive`'s own probe. Item 1 subsumes the short-circuit.
- **Item 2 flag terms**: `move()` computes `wc/bc/ep/kp` (lines 910-925)
  before the board build, so an O(1) flag delta is coherent.

### Verdicts

- **Item 1 — Check/pin-aware legality: REJECTED as proposed.** The
  checkers/pinned structural rewrite is correct in principle and would
  eliminate the mutate/undo `attacked()` calls, but: (a) the plan's Phase-4
  `king_sensitive` short-circuit already removed the dominant share of
  `attacked()` calls (274k → 89k); (b) a per-node checkers walk still pays a
  ray walk per slider direction (the same cost `attacked()` pays, ~⅓-1
  `attacked()` per node) plus the pinned computation and the 3×3 king
  neighborhood mask, which must correctly handle x-ray through the vacated
  king square; (c) the en-passant and castling edges force a slow-path
  retain. The plan's documented alternative — the make/unmake rewrite — cuts
  the same `attacked()` cost without a parallel legality model to maintain.
  The valid sub-item (measure which `attacked()` caller class dominates) is
  worth doing before committing to either rewrite. If pursued, gate on
  oracle 40/40 + perft + endgames (node counts legitimately change).

- **Item 2 — Dual-hash incremental Zobrist: VALID, SHIPPED-eligible.** The
  Phase-6 "O(1) impossible" verdict was specifically about a *single* hash
  updated by rotation deltas; the proposal's dual-hash construction is sound.
  The child board is `child[k] = -parent[121-k]` plus sparse edits, and the
  mirror/rotation component maps `h(child)` onto `hf(parent)` by the
  precomputed `zflat` table with zero per-square work, so the incremental
  hash is O(1) + O(edits). This deletes the entire 120-iteration `key()` pass
  (~1.4M `zflat` reads per 11.6k-node search) and makes the TT probe-before-
  movegen path nearly free (the probe no longer pays for hashing). It requires
  threading `_bh`/`_fh` through `move()`/`rotate()` exactly like `_king`/
  `_eking` (already threaded), and keeping the collision discipline
  (`ttK[s] == key` full-key verify). Behavior-identical — gate on the
  node-count invariant (27/258/755/4156/11653, score 41) + full suite.
  **The highest-value item of the batch.**

- **Item 3 — Leaf filter-before-sort: SHIPPED-eligible (small).** Trivially
  behavior-identical, and leaves are a large fraction of the 11.6k nodes. The
  proposed threshold/captures-only follow-up changes semantics and is correctly
  flagged as needing an A/B (quiet knight moves ~261 PST delta, king moves up
  to ~307, kp-proximity bonus ~60k). Keep the current threshold for the
  behavior-identical ship; the follow-up is a separate, measured change.

- **Item 4 — Branch-free mirror loop via flip table: REJECTED (low value,
  not low cost).** The `if k == r/s` + 3-way sign branch is real, but: (a)
  the plan's Phase-9 history shows the equivalent "flattened rays" / "flat
  attack tables" attempts were *slower* under LuaJ because per-cell branch
  removal is offset by the extra table gets/Java calls (the per-cell cost is
  dominated by the mirror copy itself, not the branch); (b) the patch
  approach requires *two* passes over the 120 cells (mirror + sparse edits),
  doubling the 120-iteration cost in the exact loop item 2 already eliminates
  for the child build; (c) item 2 makes the mirror loop O(1) by construction,
  so this is redundant. The hoisting of `2 ^ VAL_SHIFT`/`128 * 128` is valid
  and should be folded into the micro batch (item 7), not a separate change.

- **Item 5 — TT pre-size + depth-preferred replacement: PRE-SIZE SHIPPED,
  DEPTH-PREFERRED DEFERRED.** Pre-sizing `ttK/ttD/ttS/ttG/ttM` at load is
  free and removes the first-search rehash from the timed region. The
  depth-preferred replacement changes which entries survive (behavior
  change), so it needs its own A/B; pairing it with a TT_SIZE bump
  (131072/262144) is reasonable since memory is ~5 arrays of doubles. The
  stored-bound-flag suggestion is a reasonable refactor for when replacement
  is revisited (turns the usability test into one integer compare).

- **Item 6 — GC stop + wall-clock budget + VERBOSE gate: GC stop REJECTED
  (unverified), budget + gate VALID.** `collectgarbage("stop")` before search
  assumes the LuaJ build honors it and that the pool actually makes bound()
  allocation-free (pooled boards + per-ply buffers + packed ints — close, but
  `move_set_val`/`tp_set`/`tp_get` still allocate in edge cases, and the
  public `ai_move` return path builds a fresh position). Guard with pcall and
  verify on-device; the plan has no measured GC-pause signal, so this is
  speculative. The wall-clock budget at the existing yield points is nearly
  free and directly serves the Android RPD responsiveness goal — valid.
  The `SUNFISH_VERBOSE` gate for the unconditional per-depth `print` is
  already on the plan's list; valid and cheap.

- **Item 7 — Micro batch: SHIPPED-eligible (all trivial, all verified).**
  Hoist `2 ^ VAL_SHIFT`/`128 * 128` to locals; single-modulo TT probe (reuse
  the slot computed in `tp_get`, matching the not-shipped ttinline's
  microbenchmark signal); gate `print` behind `SUNFISH_VERBOSE`. All
  behavior-identical, all verified against the code. Bundle with items 2 and
  3 (per the proposal's own note that the ttinline probe was too noisy alone).

### Not in the batch (proposal's own notes, agreed)

- **`sunfish.move` one-move legality check**: valid; `legal_moves()` builds the
  whole list to validate one user move. Generate pseudo-legal, find the
  matching `{i,j}`, run `is_legal` on only that move. Noticeably snappier UI
  under LuaJ.
- **LMR revisit, later**: only after item 1 lands and per-node cost drops
  materially; the Phase-6 rejection was precisely because the unlocked extra
  depth cost more than the node reduction saved at high per-node overhead.
- **Aspiration windows**: lower priority; the per-depth binary search is
  cheap with TT repeats.

### Proposed implementation order (for the next phase)

1. **Item 2 (dual-hash) + Item 3 (leaf filter) + Item 7 (micro batch)** —
   all behavior-identical, gate on the node-count invariant + full suite +
   oracle. Item 2 is the largest win of the batch.
2. **Item 5 pre-size** — fold into the same behavior-identical batch.
3. **Item 6 budget + VERBOSE gate** — fold in; the GC-stop stays behind a
   pcall guard and is measured on-device before shipping.
4. **`sunfish.move` one-move legality** — separate behavior-identical change,
   gate on the main suite.
5. **Item 1 check/pin legality** — only after the `attacked()` caller-class
   measurement confirms the remaining calls dominate; gate on oracle + perft +
   endgames, not node counts.
6. **Item 5 depth-preferred replacement + TT_SIZE bump** — its own A/B with
   paired same-game self-play (median of ≥5 pairs), per the benchmark taste.

### Measurement notes (from the benchmark taste, applied)

- Node-count invariant (27/258/755/4156/11653, score 41) is the guard rail for
  items 2/3/5/7 — all behavior-identical.
- Item 1 changes node counts — gate on oracle 40/40 + perft 21/21 + endgames.
- Self-play ±30% variance: single pairs are uninformative — use median of ≥5
  paired games (or geometric mean) before shipping anything in the 5-15%
  range; keep BENCH_SCALE small A/Bs for anything below ~10%.

## Phase 10: behavior-identical batch — A/B results (SHIPPED: items 3, 5-pre-size, 7, move-legality; REVERTED: item 2)

The shipped-eligible items from the Post-Phase-9 review were implemented and
A/B'd as a batch under the plan's established same-JVM alternating methodology
(cold `ai_move` via `benchmarks/bench_sunfish.lua`, `BENCH_SCALE=0.01`,
`SUNFISH_NO_YIELD=1`, 3 rounds, alternating order). All items are
behavior-identical; the node-count invariant (27/258/755/4156/11653, `a8b6`,
score 41) held exactly, and the full suite stayed green
(luajit + lua5.1 + LuaJ 14/15/21 + oracle 40/40).

### Shipped (verified behavior-identical)

- **Item 3 — leaf filter-before-sort.** At `depth <= 0`, legal moves are
  filtered to the `>= 150` subset (compacted in place) before the min-heap
  sort, so the sort only sees the kept prefix — the original loop broke at the
  first `move_val < 150`, so the searched set/order are unchanged. Also hoisted
  the double `move_val(move)` decode.
- **Item 5 (pre-size) — TT arrays pre-filled at load** (`ttK = -1` sentinel,
  others 0) so the first search doesn't rehash in the timed region. The
  sentinel can't false-match (`ttK[s] == key` with keys >= 0). Depth-preferred
  replacement remains deferred (behavior-changing).
- **Item 7 — micro batch.** Hoisted `2 ^ VAL_SHIFT`/`128 * 128` to
  `VAL_SCALE`/`MOVE_MOD` (Lua 5.1 recomputed them per call); single-modulo TT
  probe (`tp_get` returns the slot, `bound()` reuses it for the bound-check
  instead of recomputing `key % TT_SIZE + 1` twice); per-depth `print` gated
  behind `SUNFISH_VERBOSE`.
- **`sunfish.move` one-move legality.** Validates one user move via
  `genMoves` + `is_legal` on the matching `{i,j}` instead of building the whole
  `legal_moves()` list. Removed the now-unused `ttfind`. Public-API behavior
  unchanged (legal/illegal/garbage moves all covered by `test_sunfish`).

### Item 2 (dual-hash incremental Zobrist): reverted, then re-shipped after the ep fix

The dual-hash was implemented and verified correct on **every** `move()`/
`rotate()` edit path (quiet, capture, castling, en passant, promotion; pooled
and non-pooled; 200-position random walk all matched the full 120-pass recompute).
The O(1) rotate (`child._bh = parent._mh`) and O(1) move deltas are sound.

**First attempt reverted**: it was not behavior-identical in the real search
(node counts 11651 vs 11653) because of a **pre-existing `_b` corruption** the
per-call `key()` masked: `is_legal`'s en-passant in-place undo wrote `-P` to
`j + S` unconditionally, which is only correct in a true en-passant setup; on
the search's pooled rotate/move children a spurious pawn leaked into `_b` (an
extra `P@d7`). The cached `_bh` hashed the clean creation board and diverged
from the mutated `_b` by one piece (constant `zflat` delta 445325827). Reverted
to the full 120-pass `key()`.

**Root-caused and fixed** (see the ep-undo note below): `rotate()` (the
null-move child) mirrored a stale `ep`, producing bogus ep moves + board
corruption. With that fixed, the dual-hash was **re-applied and is now
behavior-identical**: the node-count invariant matches the post-fix baseline
exactly (27/197/411/1818/4036/15803, `a8b6`), a 300-position random walk
(move + rotate children) matches the full recompute every time, and all suites
are green (14+15+21 + oracle 40/40).

**A/B (cold `ai_move`, same-JVM, alternating, `BENCH_SCALE=0.01`, post-fix
baseline vs dual-hash):** mod won 4 of 5 rounds (R1 -3%, R2 -23%, R3 +6%, R4
-17%, R5 -1%), mean ~-7%, identical `a8b6`/score every round. The O(1) `key()`
for search children (vs the 120-pass) is a small but consistent search-path
win; **SHIPPED**. **⚠️ REBENCH — wall-clock contaminated** (engine-internal
timer = `os.clock()` = `System.currentTimeMillis()`; loaded VM). The ~-7% is
**within the CPU-time noise band** — re-measure with `User time`/
`bench_cpu.lua` in a clean session to confirm the win before relying on it.

### En-passant undo bug: root-caused and fixed (post-Phase-10)

The `_b` corruption that reverted item 2 was traced to a genuine latent bug:

- **Root cause**: `rotate()` (used for the search's null-move child) mirrored
  the parent's `ep` (`child.ep = 121 - self.ep`). But a rotation is a **null
  move** — no pawn was pushed — so the mirrored ep target is stale. With a
  stale `ep`, `genMoves` emits bogus en-passant captures (`q == EMPTY and
  j == ep` with no enemy pawn at `j+S`), and `is_legal`'s ep undo
  (`b[j+S] = -P`) writes a phantom pawn into the pooled child's `_b`.
- **Fix** (two layers):
  1. `rotate()` now clears `ep` (the ep flag is only ever set by `move()` on a
     genuine double-push; `kp` still mirrors correctly).
  2. `is_legal`'s ep branch verifies `b[j+S] == -P` before treating a
     diagonal-to-empty move as an ep capture — defense in depth so a stale ep
     can never corrupt the board or admit an illegal capture.
- **Verified**: genuine ep captures still work end-to-end (`e5xf6` legal, the
  captured pawn is removed); after a null-move rotate no pseudo-legal move
  corrupts the board (was 2 of 30). Suites green on luajit/lua5.1/LuaJ
  (14+15+21) + oracle 40/40.
- **Search-cost side effect**: removing the bogus ep moves cuts the per-depth
  node count sharply (depth 5: 11653 -> 4036) but lets the search reach
  **depth 6** (15803 nodes) instead of stopping at the depth-5 node cap — the
  same depth-unlock pattern the LMR reversion documented. Under LuaJ's high
  per-node overhead the deeper top tree makes `ai_move` roughly neutral to
  slightly slower wall-clock (mixed A/B: -10%, +49%, -11%, +9% across rounds,
  within the +/-30% variance band). The fix is a **correctness** fix (removes a
  board-corruption source and illegal moves); its search-cost profile is a
  separate effect. `NODES_SEARCHED`/`YIELD_QUANTUM` tuning can re-balance if
  the deeper search is undesired.

### A/B timing (cold `ai_move`, same-JVM, alternating, `BENCH_SCALE=0.01`)

> **⚠️ REBENCH — wall-clock contaminated.** This table used the engine's
> internal timer, which under LuaJ is `os.clock()` =
> `System.currentTimeMillis()` — **wall-clock, not CPU time** (verified in the
> OsLib bytecode). On this loaded single-core VM, wall-clock numbers include
> load-induced waiting; the "won every round" pattern may be real or may be
> noise. **Re-measure with CPU time** (`/usr/bin/time -v` `User time`, or the
> `bench_cpu.lua` harness) in a clean session before trusting the ~-16%.

| Round | baseline | modified | delta |
|-------|----------|----------|-------|
| 1 (base first)  | 33.1s | 20.4s | **-38%** |
| 2 (mod first)   | 18.6s | 17.8s | **-4%** |
| 3 (base first)  | 24.6s | 21.2s | **-14%** |
| 4 (fresh, base first) | 22.5s | 20.3s | **-10%** |

Modified won every round regardless of order (not a cold-start artifact).
Mean ~-16%; the batch ships. Identical move (`a8b6`) and score (41) every
round — the delta is pure overhead removal, matching the doc's Phase-6/7/8
discipline. **CPU-time re-measurement pending.**

### Harness additions (committed)

- `benchmarks/ab_luaj.sh` — same-JVM alternating A/B runner (baseline/modified
  dirs, rounds, cold JVM each; handles both `bench_sunfish.lua` and
  `selfplay.lua`).
- `benchmarks/selfplay.lua` — same-game paired self-play harness (drives
  `ai_move` for both sides, `(pass)` handling, per-ply ms + TOTAL).
- `benchmarks/run_selfplay_pairs.sh` — paired same-game aggregation (median
  over N pairs).
- `benchmarks/verify_invariant.lua` — node-count/move/score invariant
  verifier (run with `SUNFISH_VERBOSE=1`).

Self-play note: full 40-ply games under LuaJ are impractical for quick A/Bs
(mid-game positions can run to depth 98 when they stay under the node cap,
taking minutes per ply), so the primary timing signal here is the cold
`ai_move` A/B — the doc's established measure for behavior-identical batches.

### Post-item-2 review: six new suggestions (A+B+C+D shipped as cleanup, E/F deferred)

A re-review after the dual-hash re-ship, focusing on what changed. First, a
**correction to the record**: the flip-table rejection rationale (c) is
factually wrong — item 2 made `key()` O(1), but it did **not** make the mirror
loop O(1): `move()`/`rotate()` still run the full 120-cell board copy on every
call. The rejection still stands on rationale (b)/Phase-9 grounds (an extra
per-cell table get for `flipT[...]` would likely lose under LuaJ, same lesson
as the flat attack tables), but the consequence matters: the 120-cell copies
are now one of the two clearly visible remaining structural costs, alongside
`attacked()`. The six new suggestions, with verdicts against the code:

| # | Item | Verdict | Notes |
|---|------|---------|-------|
| A | Skip the null-move `rotate()` at `depth <= 0` | **SHIPPED (cleanup)** | `depth > 0 and -bound(null_child, ...) or pos.score` short-circuits at leaves; the child's board is never read there, so skipping the rotate + pool alloc/free is byte-identical |
| B | Hoist the en-passant guard in `is_legal` | **SHIPPED (cleanup)** | The `p == P and (j-i)==N+W/E and q == EMPTY` test is recomputed; a precomputed `is_ep` local is identical |
| C | Skip `move_sort` when `sort_n < 2` | **SHIPPED (cleanup)** | `if sort_n > 1 then move_sort(buf, sort_n) end` skips the sort call at the many leaves with 0-1 kept moves; identical kept set/order |
| D | Capture the root move directly in `search()` (fix the `(pass)` artifact) | **SHIPPED (cleanup)** | `bound()` returns `best, bmove`; remember the last fail-high move instead of re-probing the TT after the loop (the root entry can be overwritten by a deeper transposition) |
| E | Measure `attacked()` share by caller class before choosing the legality rewrite | **VALID, next step** | Instrument `king_sensitive` probe / king-move / sensitive-touch / ep / castling; decides pin/check-aware legality vs make/unmake vs nothing |
| F | Depth-unlock consequences (budget-aware stop / TT size / aspiration) | **CONDITIONAL** | F1/F2/F3 are behavior-changing; need their own gates |

Details:

**A — skip null-move rotate at leaves.** `bound()` line 1383:
`local nullscore = depth > 0 and -bound(null_child, 1 - gamma, depth - 3) or pos.score`
already skips the recursion at `depth <= 0`, but the `m_rotate(pos, true)` at
line 1382 + `pool_free_pos` at 1384 still run (a full 120-cell copy + alloc)
for **every leaf node** — leaves are the largest node class. The child's board
is never read when the recursion is skipped, so gating the rotate itself
(`local null_child; local nullscore = depth > 0 and (null_child =
m_rotate(pos, true) and -bound(...)) or pos.score` with the free only in the
`depth > 0` branch) is byte-identical. Estimated: skips ~the leaf-fraction of
the 120-cell rotate cost — one of the two biggest remaining per-node costs.

**B — hoist the ep guard in `is_legal`.** The `p == P and (j-i)==N+W/E and
q == EMPTY` test appears at line 780 (short-circuit) and line 789 (the real
ep). Both are recomputed; a local `is_ep` from the first test is identical
(short-circuit only returns early when `not is_ep or ...`, so the second use is
only reached when `is_ep` is true anyway). Marginal but free.

**C — skip the sort for 0-1 kept moves.** After the leaf filter, `move_sort`
is called unconditionally (`move_sort(buf, sort_n)` line 1415). Many leaves
have 0 or 1 kept moves; `if sort_n > 1 then move_sort(buf, sort_n) end` skips
the call. Identical (a 0-1 element sort is a no-op).

**D — capture the root move directly.** The plan's `(pass)` artifact: the
module-level TT's root entry can be overwritten by a deeper transposition, so
the post-loop `tp_get(m_key(pos))` occasionally returns nil. Fix: have
`bound()` return `best, bmove` as a second value (the TT-hit path already
returns `es, ttM[ed_slot]`), and in `search()` remember `bmove` from the last
fail-high (`score >= gamma`) `bound` call at each depth. Cheap, removes the
`(pass)` UX artifact, cleaner self-play data. Note: this changes the search
loop's bookkeeping but not the move chosen (the last fail-high at the deepest
completed depth is exactly what the TT re-probe would return when it's not
overwritten).

**Benchmark outcome (A+B+C+D): behavior-identical, ~13% CPU-time win — shipped
as a cleanup batch (upgraded from "perf-neutral").** All gates green (node
invariant 27/197/411/1818/4036/15803 + `a8b6`; suites 14+15+21 on
luajit/lua5.1/LuaJ; oracle 40/40; 300-position hash walk). Initial wall-clock
A/Bs on the single-core busy VM looked perf-neutral (base 11.7/11.5/12.8s vs
mod 12.9/11.9/12.3s), but that was wall-clock noise. Re-measured with
**OS-level CPU time** (`/usr/bin/time` `User time`, load-immune, stable to
~0.1s across runs): base 13.24/13.34s (mean 13.29) vs mod 12.64/10.38/11.43s
(mean 11.48) — **mod ~13.6% faster CPU, winning all three runs**. The
wall-clock spread was load-induced waiting, not engine time. Note: LuaJ's
`os.clock()` is `System.currentTimeMillis()`-based (verified in the bytecode),
i.e. wall-clock, NOT CPU time — never trust engine-internal "ms" on a loaded
machine. ThreadMXBean thread-CPU also reported ~0 on this VM, so
`/usr/bin/time` `User time` (minus the ~0.36s JVM-startup CPU constant) is the
reliable CPU measure here.

**Machine note**: this repo is benchmarked on a single-core 1 GB VM with
frequent load spikes (19 users; load avg 1.5-3.9 observed). All cold-JVM A/Bs
must run **sequentially** (never in parallel), and **CPU time
(`/usr/bin/time -v` `User time`) is the signal** — wall-clock and LuaJ
`os.clock()` are both load-contaminated. `benchmarks/bench_cpu.lua` +
`LuajCpuRun` launcher provide the harness (though ThreadMXBean is broken on
this VM, the `os.cpuclock()` hook remains for machines where it works).

**E — measure `attacked()` share by caller class.** With `key()` O(1) and the
TT probe nearly free, the 54% `is_legal`/`attacked`/`genMoves` share is almost
certainly higher now. The plan's check/pin-legality verdict is defensible (the
`king_sensitive` short-circuit already captured most of it, and the
x-ray/ep/castling edges force slow paths), but its "valid sub-item" — count
`attacked()` calls by caller class (king_sensitive probe / king moves /
sensitive-touch / ep / castling) — is the right next step. That single profile
decides between:
- pin/check-aware legality (wins if sensitive-touch dominates),
- make/unmake (wins if king-move and castling tests dominate),
- or nothing (if the residual is small enough that A-C are the better spend).

Given rotation makes classic make/unmake awkward (frame flip per ply), a
**hybrid** is worth noting: keep the copy model but apply A-C, then re-profile.
If `attacked()` is still >30% of LuaJ time after that, the rewrite is clearly
worth its risk.

**F — depth-unlock consequences.** The ep fix cut depth-5 nodes 11653->4036 and
the search now runs depth 6 (15,803 nodes — a 58% overshoot of
`NODES_SEARCHED = 10000`, since the budget is only checked between depths).
Three levers, in increasing order of risk:
- **F1 budget-aware stop**: check `nodes >= maxn` at the yield points and abort
  gracefully, or retune `NODES_SEARCHED` (~6500) for the old time/strength
  point. Also pending: the wall-clock deadline at yield points
  (`sunfish.settime_budget`).
- **F2 TT replacement + size**: more compelling now — 15.8k nodes/move with a
  TT that persists across a game will saturate 64k slots. Add a probe/hit
  counter first, then A/B `depth + 2 >= ttD[s]` and `TT_SIZE 131072/262144` as
  its own paired self-play test, per the plan's protocol.
- **F3 aspiration windows**: with depth 6 now the dominant per-depth cost,
  narrowing the root window around the previous depth's score (re-widening on
  fail) is slightly more attractive than before. Node-count-changing ->
  oracle/perft gate. LMR stays parked until E lands.

**One small Android note**: `VERBOSE` reads `os.getenv` at module load; on the
device you likely can't set env vars at runtime, so for debug output from a
release build add a `sunfish.set_verbose(flag)`.

**Suggested order**: A + B + C as the next behavior-identical batch (gate:
node invariant 27/197/411/1818/4036/15803 + suites), D alongside, then E's
instrumentation before any structural rewrite, and F2/F1 as their own A/Bs.

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
| 8 | Pooled move buffers + count-driven min-heap sort (per-ply move_stack, genMoves(out,start), no `#`/table.sort) | 1.2-1.5x on top of Phase 7 | Med (per-ply buffer invariant) | **DONE** |
| 9 | Full 1-based indexing (squares/packed moves/constants/mirrors `121-x`) + sentinel-terminated rays | ~1.2-1.4x on top of Phase 8 (`move` ~2x) | Med (mirror/pst/sentinel pitfalls, documented above) | **DONE** |

Cumulative target: **~21s -> 3-5s** per `ai_move` under LuaJ.
Current: **~15.9s (Phase 1) -> ~14.2s (Phases 2-4) -> ~12.5s (Phase 5) -> ~8-11s
(Phase 6) -> ~10-11s (Phase 7) -> ~11s (Phase 8 pooled-moves) -> ~10-12s
(Phase 9 1-based)**. The move-gen
and lifecycle paths are 2-3.4x faster; `ai_move` (search) gained ~27% cumulative
through Phase 5, a further ~30-55% from the Phase-6 method hoisting + 64-square
+ value-hoist + king-propagation + parallel-TT batch, ~14-37% (mean ~19%) from
Phase-7 board/Position pooling, ~21-51% (mean ~33%) from Phase-8 pooled
move buffers + count-driven sort (same-JVM A/B, identical move selection every
round), and ~20-40% from Phase-9's full 1-based indexing (with the public
`move` path roughly 2x and ~2.8x with the sentinel rays). The remaining search
time is dominated by `is_legal`'s `attacked()`
walks; the full make/unmake rewrite is the known next step but carries the
documented recursion-corruption risk.

## Validation per phase

- `luajit` + `lua5.1` run `tests/test_sunfish.lua` (14) and
  `tests/test_endgames.lua` (15) — all green.
- `python3 tests/compare_python_chess.py` — 40/40 legal-move oracle.
- `TEST_BUDGET=120 benchmarks/run_luaj.sh tests/test_sunfish.lua` under LuaJ.
- `BENCH_SCALE=0.01 benchmarks/run_luaj.sh` — record `ai_move` ms / `move` iter/s.
- Self-play: `lua selfplay.lua <engine_dir> <plies>` — same-game paired timing
  comparison (primary benchmark for search-path changes).

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
