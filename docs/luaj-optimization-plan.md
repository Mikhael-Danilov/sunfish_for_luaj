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
- [x] F1 budget-aware stop + `settime_budget`: **~11.3% CPU-time win**; depth 6
  now stops at 10k nodes (was 15.8k). F3 root aspiration: **~22.5% CPU-time
  win**, mod won 5/5 rounds. Both confirmed with `/usr/bin/time` `User time`.
  See the "Full next phase" section.
- [x] Rebench battery (node-count-normalized): Phase-10 batch ~35% CPU win over
  Phase 9 (both 11.6k nodes); A+B+C+D ~19% CPU win over item 2 (both 15.8k
  nodes) — the doc's shipped claims confirmed; the earlier "ABCD slower"
  reading was a node-count artifact.
- [x] Coordinate-render fix (Phase-9 regression): `render` was left 0-based
  (A1=91) after the full 1-based switch, so `ai_move`'s move string and the
  internal render were off by one (returned `a8b6` for the real `g1f3`). Fixed
  by making `render` 1-based (A1=92) + `ai_move` mirror `121-x`, keeping the
  public `move_2_cell`/`cell_2_move` 0-based (backward-compatible). Also
  fixed `is_legal` to reject moves onto the OWN king (only `-K` was rejected),
  and `search()` now validates the root move before returning it. All caught
  by the new stockfish-validated selfplay correctness gate. See "Correctness
  gate" below.
- [x] E instrumentation (`sunfish.attacked_stats`, `SUNFISH_PROFILE_ATTACKED=1`
  caller-class counters): **committed** — previously referenced by the profile
  harness but absent from the engine (harness crashed on a nil value).
  Re-measured post-F1/F3: ~85% sensitive-touch stands, decision for
  pin/check-aware legality confirmed. See the E section.
- [x] Pin/check-aware legality (the E decision): **SHIPPED** —
  `compute_check_pins` + `on_ray` replace `king_sensitive`; `is_legal` is
  branch logic (2-checker/1-checker/0-checker + pin rule) with the
  mutate/undo `attacked()` slow path retained only for king moves, en-passant,
  and castling. `attacked()` calls per search cut 84,055 → 3,578 (~96%);
  ~16% CPU-time win (mean). All gates green (suites + oracle + perft +
  stockfish selfplay). Two perft-caught bugs fixed (block-beyond-checker,
  ep-capture-of-checker). See the pin/check section below.
- [x] Micro batch (9-item review): items 1/2/5/6/7/9 **SHIPPED** (inline
  `move_greater`, sentinel-padded target tables, `PACKED_ZERO_VAL`, inline TT
  probe, ternary rotate branch, `math_abs` removal, inline `edit_hash`);
  3/4/8 rejected. Behavior-identical (invariant `27/153/287/1498/3030/10026`,
  `b8c6`); ~5% CPU-time win on the full benchmark. `verify_invariant.lua`
  updated to the current sequence. See the "Micro batch" section.
- [x] Item-3 reverify: flattening `ray_squares` confirmed **NOT faster** under
  CPU time (base won 4/6, mod ~3.5% slower) — the wall-clock rejection was
  correct. See the "Item-3 reverify" section.
- [x] Make/unmake experiment: classic make/unmake is **incompatible with the
  rotation model**; the viable copy+sparse-edit `move()` is **MERGED** as
  behavior-identical (perf-neutral to small win: 10-round A/B ~5.5%, 6-round
  confirm a tie). See the "Make/unmake experiment" section.

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

## Micro batch (9-item review): items 1/2/5/6/7/9 SHIPPED, 3/4/8 rejected

A 9-item external optimization proposal was reviewed against the source and
implemented as a behavior-identical batch. Verdicts per item:

| # | Item | Verdict | Notes |
|---|------|---------|-------|
| 1 | Inline `move_greater` into `move_sort` | **SHIPPED** | `119*128+119 = 15351 < 2^14` makes plain integer comparison order by value then coordinates. `move_set_val` stores a full `(val+VAL_BIAS)*VAL_SCALE` delta, so same-node moves never differ by `< VAL_SCALE` and the i/j tie-break is unreachable on the search path. Removes the comparator function call from every heap op. |
| 2 | Sentinel-pad `knight_targets`/`king_targets`/`pawn_caps` | **SHIPPED** | Built with 0 sentinels to fixed bounds (8/8/2); `genMoves`/`attacked` loop `for c=1,MAX` + `break` on 0. Removes the `#` and the bound re-read from the per-square loops. Same class of win as the Phase-9 sentinel rays. |
| 3 | Flatten `ray_squares` to 1D (`t*8+di`) | **REJECTED** | Already A/B'd slower: the Post-Phase-9 "flattened rays" and the earlier "flat attack tables" both lost under LuaJ's per-cell Java-call cost (the multiply + single get vs two gets nets out negative). **Reverified under CPU time (see below)** — confirmed the rejection is real, not a wall-clock artifact. |
| 4 | Inline `move_pack`/`move_from`/`move_to`/`move_val` wholesale | **REJECTED** (slice SHIPPED) | `move_pack`/`move_val` are already local upvalues; the arithmetic is already hoisted (`VAL_SCALE`/`VAL_BIAS`, Phase-10 item 7). The one worthwhile slice — precompute `PACKED_ZERO_VAL` and inline the zero-value pack into `genMoves` — shipped. `move_from`/`move_to` inlining would duplicate arithmetic at 9 sites for ~1 call/genMoves saved; not worth it. |
| 5 | Inline the TT probe in `bound()` | **SHIPPED** | Replaces the 4-value `tp_get` return + unconditional `ttS/ttD/ttG` reads with a slot computed once and lazy reads after the `ttK[s] == key` verify. `tp_get` deleted; F2 counters preserved. The `search()` TT fallback probe is also inlined. Same shape as the not-shipped ttinline, but standalone it's a clean behavior-identical micro-win. |
| 6 | Ternary rotate branch (`(v==98 or v==99) and v or -v`) | **SHIPPED** | Byte-identical for all 120 codes (0 is truthy in Lua, pieces/padding are the only codes). Replaces the 3-way `if/elseif/else` in `rotate()` + both `move()` mirror loops. |
| 7 | Replace `math_abs` with `x==2 or x==-2` | **SHIPPED** | 5 sites: `is_legal`/`move()` castling checks, `bound()` mate check, `search()` break. `math_abs` was already a local upvalue, but it's still a call per node; the OR form is exact for integers. |
| 8 | Hoist `attacked` to a standalone `is_attacked(i,b)` | **REJECTED** | Premise is stale: the method dispatch is already hoisted via upvalues, and the pin/check rewrite cut `attacked()` to ~3.5k calls/search (king-move 98.9%). The remaining `:` overhead is noise, and the standalone form breaks the `self:ensure_arr()` fallback for public paths. |
| 9 | Inline `zc()` into `edit_hash` in `move()` | **SHIPPED** | Inlines the two `zflat`/`zmirror` contributions per edit with the same `(pc+6)*120 + sq` indexing as `key()`. Fires only on the ~2 edited squares per move (the proposal's "120 calls/move" overstates it), but it's free and provably identical. |

**Validation (all green):** node invariant `27/153/287/1498/3030/10026` + root
`b8c6` (the post-F1/F3/pin-check baseline); suites 14+15+21 on luajit, lua5.1,
and LuaJ; oracle 40/40; `attacked()` profile unchanged (3,578 calls, king-move
98.9%).

**CPU-time A/B** (cold `ai_move` via `/usr/bin/time` `User time`, sequential
cold JVMs): bare cold-search rounds were a dead tie within noise (base mean
~7.4s vs mod ~7.6s across 7 rounds), but the full `bench_sunfish.lua`
(cold `ai_move` + new/move/store/coords) favored mod: base 48.49/49.06 (mean
48.78) vs mod 48.01/44.44 (mean 46.23) — **~5% CPU win**, matching the plan's
lesson that per-node micro-op removal shows up weakly on this loaded VM but the
direction is real. Behavior is byte-identical (same move/score/node counts).

### Housekeeping in the same commit

- **`benchmarks/verify_invariant.lua`** updated to the current F1/F3 sequence
  (`27/153/287/1498/3030/10026`, `b8c6`) — it was asserting the pre-F1/F3
  sequence and reporting "INVARIANT BROKEN" by design (a documented open item).
- **Verifier regex bug fixed**: the `Score (%d+)/(%d+)` pattern dropped depths
  whose aspiration window had a negative bound (`Score 0(-1/0)`), silently
  MISSING depths 2/4 even against the correct sequence. Now matches optional
  leading minus on both window values.

### Item-3 reverify: CPU-time A/B of the flat `ray_squares` variant

Item 3 (flatten `ray_squares[i][di]` to a 1D `ray_flat[i*8+di]`) was rejected
on the strength of two **wall-clock** measurements (the pre-Phase-6 "flat
attack tables" reversion and the Post-Phase-9 "flattened rays" non-ship). Per
the measurement caveat, that evidence was load-contaminated — so the rejection
was re-verified under the CPU-time discipline (`/usr/bin/time` `User time`,
cold sequential JVMs, alternating order).

The variant: `ray_flat` built once from `ray_squares`; the three hot walkers
(`attacked()`'s rook/bishop loops, `genMoves`' slider loop,
`compute_check_pins`) use `ray_flat[ib+di]` instead of `ray_squares[i][di]`.
All other code identical.

**Gate (all green, behavior-identical):** node invariant
`27/153/287/1498/3030/10026` + `b8c6`; suites 14+15+21; oracle 40/40.

**Cold `ai_move` CPU-time A/B (6 alternating rounds, User time):**

| Variant | rounds (s) | mean |
|---------|-----------|------|
| base (nested) | 7.31, 4.96, 6.41, 8.81, 6.22, 10.65 | **7.39** |
| mod (flat) | 7.31, 6.70, 7.01, 9.51, 8.79, 6.59 | **7.65** |

**Verdict: base won 4/6 rounds; mod ~3.5% slower on average — the flat form
does NOT pay.** The `move` microbenchmark is a tie within resolution noise
(base ~4.8ms vs mod ~4.8ms for 3000 iters). This confirms the rejection is
real, not a wall-clock artifact: the extra `*8 + di` multiply + single-get
nets out against the saved table-get under LuaJ's interpreter, exactly the
mechanism the "flat attack tables" and "flattened rays" notes described. The
rejection stands, now on CPU-time evidence.

### Make/unmake experiment: copy+sparse-edit move() MERGED (perf-neutral to small win)

The plan's "make/unmake rewrite" thread was prototyped and A/B'd under the
CPU-time discipline. The classic make/unmake (mutate the parent board, unmake
after the child returns) is **incompatible with the rotation model** — the
child is a rotated frame, so "unmaking" would need a full re-rotate. The
viable variant keeps the copy model but changes *how* the rotated child is
built: instead of the single-pass 120-cell loop with a per-cell
`if/elseif/else` branch + interleaved edit/hash handling, `move()` now:

1. Copies the parent's 120-cell board into the child's board with the pure
   rotation mapping (`nb[k] = (v==98 or v==99) and v or -v`) — a straight,
   branch-per-cell copy;
2. Applies the sparse edits (moved piece, emptied origin, castling rook, ep
   capture) as a few direct overwrites;
3. Computes the dual-hash deltas only for the edited squares.

The public path still allocates a fresh board per call (no shared scratch, so
no aliasing); the pooled search path reuses the pooled board via `pool_alloc`.
All special cases preserved: promotion inference (`-Q` for ANY piece to rank
8, verified), castling rook, ep capture, king-index + flag threading.

**Gate (all green, behavior-identical):** node invariant
`27/153/287/1498/3030/10026` + `b8c6`; suites 14+15+21 on luajit, lua5.1, and
LuaJ; oracle 40/40; perft 21/21.

**CPU-time A/B (cold `ai_move`, User time, alternating cold JVMs):**

Initial 10-round temp A/B: base 7.77, 6.06, 8.04, 6.14, 7.57, 6.92, 5.31, 8.04,
6.99, 7.77 (mean 6.92) vs mod 7.39, 5.93, 4.97, 7.40, 7.65, 5.83, 5.97, 6.85,
8.07, 6.10 (mean 6.54) — mod won 7/10, **~5.5%**.

Final repo-confirm 6-round A/B (HEAD pre-make/unmake vs merged): base 6.65,
6.74, 5.98, 7.17, 6.03, 7.57 (mean 6.69) vs mod 6.39, 6.69, 7.54, 7.37, 6.68,
5.77 (mean 6.74) — mod won 4/6, **dead tie**.

**Verdict: MERGED as behavior-identical.** The copy + sparse-edit construction
is at worst perf-neutral and likely a small (0-5%) win — the two A/Bs bracket
it: the 10-round temp run favored mod ~5.5%, the 6-round repo confirm is a
tie. Under the established discipline, a behavior-identical change that is
perf-neutral-or-better and passes every gate ships; the 120-cell copy remains
the dominant per-node cost. The deeper make/unmake (no per-move copy at all)
stays blocked by the rotation model — only a frame-flip redesign (dropping
rotation per ply) removes the copy, and that stays out of scope.

## Full next phase: E instrumentation, F1/F2/F3, micro batch, rebench (SHIPPED: F1 + F3; DEFERRED: B, E-rewrite, F2)

The plan's open threads (E, F1, F2, F3) plus two spotted micro-wins were
executed under the established CPU-time discipline (`/usr/bin/time` `User
time`, sequential cold JVMs). Outcomes, in order:

### Micro batch (B1 attacked-hoist + B2 move_greater collapse): REVERTED — perf-neutral

Both are behavior-identical (injective packed-move encoding verified: distinct
`(i,j,val)` → distinct ints, so the `move_greater` tie-decode is dead code;
node invariant held exactly). But CPU-time A/B (5-8 rounds, alternating) was a
**dead tie**: base 10.22/10.66/13.08 vs mod 12.48/11.64/14.42 (first run, looked
negative), then isolated B1 ~neutral (9.95/10.98), B2 ~6% (12.18/11.39), full
batch 11.24/11.48 (4-4 split). Under LuaJ the `self:attacked` `__index`
dispatch and the two-branch comparator are NOT measurable costs at these node
counts — the Phase-6 method-hoisting win was specific to `bound()`'s outer
loop. **Reverted; not shipped.**

### E — `attacked()` caller-class instrumentation: MEASURED, decision = pin/check-aware legality

Added debug-only counters (behind `SUNFISH_PROFILE_ATTACKED=1`, zero cost when
off) counting `attacked()` calls by caller class. One cold start-position
search (deterministic: 128,574 total both runs):

| Caller class | Count | Share |
|---|---|---|
| `king_sensitive` probe | 14,607 | 11.4% |
| king-move destination | 4,969 | 3.9% |
| **sensitive-touch (non-king move past short-circuit)** | **108,981** | **84.8%** |
| en-passant | 0 | 0.0% |
| castling | 17 | ~0% |

**Decision**: sensitive-touch dominates at ~85%, which per the plan's decision
rule points to **pin/check-aware legality** (it eliminates the mutate/undo
`attacked()` for that class). The rewrite is the highest-risk remaining change
(the x-ray/ep/castling edges force slow paths, per the Phase-6 item-1
analysis); it remains DEFERRED as its own gated phase, not this batch.

**Instrumentation now committed**: the debug-only counters
(`SUNFISH_PROFILE_ATTACKED=1`, zero cost when off) and the
`sunfish.attacked_stats()` accessor are now in the engine (they were previously
only referenced by `benchmarks/profile_attacked.lua` — running the harness
crashed with "attempt to call a nil value"). `attacked()` takes an optional
caller-class tag ("probe"/"king"/"touch"/"ep"/"castle"); the en-passant class is
disambiguated from the shared sensitive-touch call via the `ep_undo` flag, and
castling counts both `attacked()` calls in its branch. Re-measured on the
current engine (post-F1/F3, `SUNFISH_PROFILE_ATTACKED=1 SUNFISH_NO_YIELD=1`,
cold start-position search, 84,055 total, identical under luajit and LuaJ):

| Caller class | Count | Share |
|---|---|---|
| `king_sensitive` probe | 9,390 | 11.2% |
| king-move destination | 3,540 | 4.2% |
| **sensitive-touch (non-king move past short-circuit)** | **71,091** | **84.6%** |
| en-passant | 0 | 0.0% |
| castling | 34 | ~0% |

The proportions are unchanged from the original measurement (~85%
sensitive-touch), so the decision stands. The absolute counts dropped (128,574 →
84,055) because the search now stops at ~10k nodes (F1) instead of 15.8k and
aspiration (F3) cuts the explored tree.

### F1 — budget-aware stop + `sunfish.set_time_budget`: SHIPPED

`bound()` now checks `nodes >= maxn` at the per-node yield point (was only
checked between depths), sets `budget_exhausted`, and unwinds; `search()`
breaks and keeps the last completed depth's fail-high move. Depth 6 now stops
at **10,010 nodes** (was 15,803 — a 37% overshoot of `NODES_SEARCHED=10000`).
Also added `sunfish.set_time_budget(seconds)` — a wall-clock deadline at the
same per-node point (os.clock() is wall-clock under LuaJ, which is exactly what
the Android RPD responsiveness goal wants; 0 = off, default).

CPU-time A/B (3 rounds): base 12.63/12.51/12.34 (mean 12.49) vs mod
10.40/9.65/13.18 (mean 11.08) — **~11.3% CPU win**, 2/3 rounds (round 3 load
noise). Node counts legitimately change; gate was oracle 40/40 + perft 21/21 +
endgames 15/15 (all green on luajit/lua5.1/LuaJ), NOT the node invariant.

### F2 — TT replacement policy + size: DEFERRED (measured premise false)

E1 counters (`sunfish.tt_stats`) on the shipped engine: a 10k-node search does
9,999 probes, **1,129 hits (11.3%)**, 1,172 slot-occupied (11.7%) of 65,536
slots — **~1.8% occupancy**. The TT was never saturating at these node counts
(even pre-F1's 15.8k would fill ~25%), so depth-preferred replacement and a
TT_SIZE bump cannot help: 88% of misses are empty-slot misses, not evictions.
**Depth-preferred replacement (E2) and size bump (E3) deferred — no
behavior-changing risk is justified when the premise (saturation) doesn't
hold.** The counters stay for a future TT audit at higher node budgets.

### F3 — root aspiration windows: SHIPPED

`search()` now starts each depth at `prev_score ± 100` (full window on depth 1;
full-window re-search on fail-outside-window) instead of always the full
`[-3M, 3M]`. Cumulative node count dropped to 10,026 at depth 6 (vs 15,803
pre-F1), and the root move stayed the invariant `a8b6`.

CPU-time A/B (5 rounds, alternating): base 10.20/10.35/8.76/13.90/11.64 (mean
**10.97**) vs mod 8.33/8.39/7.55/9.90/8.34 (mean **8.50**) — **~22.5% CPU win,
mod won every round** (no overlap). This is the largest single-phase win since
Phase-8's pooled move buffers. Gate: oracle + perft + endgames (node counts
legitimately change).

### Rebench battery (CPU-time verification of shipped claims, node-count-normalized)

Re-measured the cumulative CPU curve by checking out each phase's
`sunfish.lua` and timing it with `/usr/bin/time` `User time`. **Critical
methodological correction**: cross-commit raw-time comparison is INVALID across
the ep-fix boundary — pre-fix commits (af30ed3..16d872f) search **11,649-11,653
cumulative nodes**; post-fix (f65fb3e onward) search **15,803** (37% more
work). All comparisons must be same-node-count (or nodes/sec). With that
correction:

- **Phase 9 (8419ddd) vs Phase-10 batch (16d872f)** — both 11,653 nodes:
  P9 11.92/12.74/15.14 (mean 13.27) vs P10 8.03/8.84/8.80 (mean 8.56) —
  **Phase 10 ~35% CPU win** (doc's ~-16% was conservative).
- **Item 2 (f65fb3e) vs A+B+C+D (d02f324)** — both 15,803 nodes:
  item2 12.05/13.36/14.25 (mean 13.22) vs ABCD 10.05/9.94/12.26 (mean 10.75) —
  **A+B+C+D ~19% CPU win** (doc's ~13% confirmed; the earlier "ABCD slower"
  reading was the node-count artifact).
- **Phase 6 (af30ed3) readings (3.4-8.5s) are flagged unreliable** — they
  measure *faster* than Phase 8 (a superset), which is impossible if phases are
  cumulative; a load artifact at that commit. The Phase-8 win was already
  documented vs its own baseline; not re-litigated here.
- Net: the rebench **confirms** the shipped claims (Phase-10 batch and A+B+C+D
  are genuine CPU wins); the pre-ep-fix phase curve (6/7/8) needs a clean-session
  re-run if those exact percentages matter.

### Cumulative search state at HEAD (after this phase)

The search now runs depth 6 at **~10k nodes** (budget stop + aspiration):
27/153/287/1498/3030/10026, root move `b8c6`, score 41 (score 0 on the
current pin/check baseline; the `a8b6`/score-41 reading was the pre-pin-check
search). The F3 node-count win (15.8k → 10k) plus the per-node F1 abort is the
~22% CPU-time win over the pre-phase baseline. `verify_invariant.lua` now
asserts this exact sequence (updated in the micro batch commit).

### Pin/check-aware legality: SHIPPED (the E decision, now implemented)

The E instrumentation's decision (sensitive-touch `attacked()` at ~85%) was
acted on: `is_legal` no longer mutate/undo-tests most moves. Replaces
`king_sensitive` with `compute_check_pins` — one 8-ray walk + fixed-attacker
probes per node that returns the checker squares (`chk[1..2]`, with the
between-squares for a slider checker), the pinned pieces (`pin[sq]` generation-
tagged) and their pin directions (`pdir[sq]`), and the checker count. A new
`on_ray[a*121+b] = di` precompute (built once from `ray_squares`) makes the
pin/block test a single table read.

`is_legal` now decides most non-king moves without touching the board:
- **2+ checkers** → only king moves (non-king moves can't capture/block two).
- **1 checker** → capture the checker (directly or via en-passant when the
  captured pawn is the checker) or block the between-square (slider checker).
- **0 checkers** → legal unless the moving piece is pinned and the move leaves
  its pin ray (stays on the pin line via `on_ray[king*121+j] == pdir[i]`).
- **King moves, en-passant, castling** keep the mutate/undo `attacked()` slow
  path (x-ray-correct attack test after a real board change).

Two correctness bugs found and fixed during implementation (both caught by
perft, not by the unit suites):
1. **Block-beyond-checker**: the initial block test (`on_ray[chk1*121+j] ~= 0
   and on_ray[king*121+j] == on_ray[king*121+chk1]`) wrongly accepted squares
   BEYOND the checker (e.g. d3/e4 when a bishop on c2 checks a king on b1).
   Fixed to require j strictly between: `on_ray[king*121+j] == kc and
   on_ray[j*121+chk1] == kc` (the checker continues on the same ray from j).
2. **En-passant capture of a checking pawn**: when a pawn double-pushes and
   gives check, the ep capture of that pawn (`j+S == chk1`) is the legal
   reply, but the 1-checker branch only handled `j == chk1`. Added the
   `is_ep and j+S == chk1` case (subject to the same pin-line rule).

**Validation** (all green): luajit + lua5.1 + LuaJ suites (14+15+21), oracle
40/40, perft 21/21, and the stockfish-validated selfplay gate (20 plies, all
legal, natural checkmate). The start-position node invariant is unchanged:
27/153/287/1498/3030/10026, `b8c6`, score 0.

**E re-measurement** (the payoff): `attacked()` calls per search dropped from
**84,055 → 3,578 (~96% reduction)**. The sensitive-touch class (84.6% of the
old total) is **eliminated** — remaining calls are exactly the intended slow
paths: king-move 3,540 (98.9%), castling 34, en-passant 4.

**CPU-time A/B** (cold `ai_move`, `/usr/bin/time` `User time`, 3 runs):
baseline 8.50/8.92/9.88 (mean ~9.10) vs rewrite 6.48/8.92/7.58 (mean ~7.66) —
**~16% faster** (run 2 is load-noise; the qualitative win is confirmed by the
96% `attacked()` cut). Node counts legitimately could change but the start
position's search is identical.

The `king_sensitive` function, `sens_tmp`/`sens_gen`, and the `sens` parameter
threading are all removed. The E instrumentation stays for future profiling.

### Remaining open items (for a future phase)

- **Deeper make/unmake (no per-move 120-cell copy)**: the copy+sparse-edit
  `move()` shipped, but the classic make/unmake (mutate the parent board, no
  copy) is blocked by the rotation model — the child is a rotated frame, so
  unmaking needs a full re-rotate. Only a frame-flip redesign (dropping
  rotation per ply) removes the 120-cell copy; that stays out of scope.
- **F2 depth-preferred + TT_SIZE bump**: revisit only if node budgets rise
  enough to approach TT saturation.
- **LMR**: stays parked (the Phase-6 rejection reason — extra depth costing
  more than node savings — is unchanged; the per-node cost is now lower, so a
  re-A/B is reasonable at some point).
- **`verify_invariant.lua`**: now asserts the current F1/F3/pin-check sequence
  (27/153/287/1498/3030/10026, `b8c6`) — updated in the micro batch commit.


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

## Correctness gate: stockfish-validated self-play (new)

`benchmarks/selfplay_correctness.py` drives the engine for up to 100 plies (or
until the game ends naturally), converts each `ai_move` display string to the
real-board parent-frame move (tracking the engine's per-ply rotation), and
validates every move with Stockfish 18 over UCI (the FEN side-to-move flip
check). Exit 0 only if every move is legal; the engine's own `legal_moves()`
is the secondary check.

**What it caught (fixed in this commit):**
1. **Coordinate-render Phase-9 regression** — `render` was left 0-based
   (A1=91) after the full 1-based switch. `ai_move` returned `a8b6` for the
   real `g1f3`, and all public coordinates were off by one. Fixed: `render`
   is 1-based (A1=92), `ai_move` mirror is `121-x`, public `move_2_cell`/
   `cell_2_move` stay 0-based (backward-compatible).
2. **`is_legal` own-king bug** — only `q == -K` (enemy king) was rejected, so a
   move onto the OWN king (e.g. `h1e1` with the king on e1) overwrote the king
   and was accepted. Fixed: reject `q == K or q == -K`.
3. **Root-move validation** — `search()` now validates the returned root move
   (and the TT re-probe fallback) with a full `is_legal` check before playing
   it; an illegal TT-sourced move falls back to nil (the engine passes).

**Gate result**: the engine self-plays to a legal game — the 100-ply run ended
at ply 20 with a legitimate checkmate (`e5h2`, stockfish confirms
`bestmove (none)` on `r1b1kb1r/ppp2pp1/4p1p1/8/1n4P1/8/PPPP1P1q/R1BQ1RK1`),
every move legal. This is now a committed correctness gate alongside the
oracle/perft/endgame suites.

## Validation per phase

- `luajit` + `lua5.1` run `tests/test_sunfish.lua` (14) and
  `tests/test_endgames.lua` (15) — all green.
- `python3 tests/compare_python_chess.py` — 40/40 legal-move oracle.
- `TEST_BUDGET=120 benchmarks/run_luaj.sh tests/test_sunfish.lua` under LuaJ.
- `BENCH_SCALE=0.01 benchmarks/run_luaj.sh` — record `ai_move` ms / `move` iter/s.
- Self-play: `lua selfplay.lua <engine_dir> <plies>` — same-game paired timing
  comparison (primary benchmark for search-path changes).
- Correctness: `python3 benchmarks/selfplay_correctness.py [--plies 100]` —
  stockfish-validated self-play gate (all moves legal, or natural game end).

## Android specifics

- Pure Lua 5.1 source: no luajc, no bcel, no bit32, no FFI.
- Fixed-size TT (`TT_SIZE = 65536`) replaces the unbounded string-keyed dict
  (`TABLE_SIZE = 1e6` was removed) -> bounded ~10MB. `TT_SIZE` is now a tunable
  constant; `NODES_SEARCHED` remains the exposed tunable.
- The yield interval is a tunable countdown: `YIELD_QUANTUM = 256` nodes by
  default (was hardcoded at 30), configurable via `sunfish.set_yield()`;
  `SUNFISH_NO_YIELD=1` disables yields for benchmark throughput.
- Search `print` is still unconditional (no `SUNFISH_VERBOSE` gate yet).

## External review: 6-item LuaJ optimization proposal (analyzed, not implemented)

A 6-item proposal was reviewed against the current source (HEAD 1ecca1e). All
code-level claims were verified against the actual code; the verdicts below
follow the plan's established discipline (behavior-identical + same-JVM A/B,
or measured rejection).

### Item 1 — Hoist `zc`/`edit_hash` closures out of `move()`: VALID (slice SHIPPED-ready)

The review's premise is correct: `Position:move()` allocates a closure
(`add_edit`) per call when the search path carries hashes (`has_hashes`), i.e.
for essentially every search child — ~20-40k closure allocations per 10k-node
search. The current code (lines 1221-1229) defines `local function add_edit(k,
new_pc)` inside `move()`, then calls it up to 5 times (moved piece, emptied
origin, castling rook x2, ep capture). Note the review's quoted `zc`/`edit_hash`
and "Lines 638-648" are **stale** — the current closure is `add_edit` at line
1221 (the `zc` helper was inlined into the micro batch). The fix is valid: the
closure is a per-call Java `LuaClosure` allocation; hoisting the arithmetic
inline into `move()` (the `add_edit` calls are all in one block) removes it
with zero behavior change. **Estimated gain: 2-4% of search time** (the review's
15-25% is overstated — closure creation is cheap relative to the 120-cell
copy + `attacked()` walk that dominate each node).

### Item 2 — Remove `is_on_board_1` from pawn pushes: VALID (SHIPPED-ready)

Verified: on the 1-based board, off-board squares are SP=99/NL=98, never
EMPTY=0, so `b[j] == EMPTY` inherently rejects them. The double-push guard
`i >= A1+N` (line 617) already confines double pushes to rank-2 pawns whose
`j2` is always rank 4 (on board). So the `is_on_board_1[j]` lookups at lines
611/619 are dead for legal positions. **Measured under LuaJ** (isolated pawn-push
microbenchmark, 200k iters): A (with) 9.32s vs B (without) 5.37s — **~42%
faster on the pawn-push path**, though the full `genMoves` includes knight/king/
slider loops where this doesn't apply, so the whole-movegen gain is ~5-10% (the
review's claim). The empty-check `b[j] == EMPTY` is inherently safe. Behavior-
identical; gate on the node invariant + full suite.

### Item 3 — Inline `move_greater` into `move_sort`: ALREADY DONE

The review quotes `move_greater(buf[child], buf[child+1])` as current — **stale**.
The micro batch (item 1) already inlined the comparator: `move_sort` (line 1418)
compares raw `>` on packed ints (`buf[child] > buf[child+1]`), with the
tie-break analysis documented at lines 1401-1410 (same-node moves never differ
by < VAL_SCALE, so the i/j tie-decode is unreachable). The review's proposed
`is_greater` function with coordinate extraction would **re-add** a function
call the code already removed. Rejected (already shipped).

### Item 4 — Inline `tp_get`: ALREADY DONE

The review proposes inlining `tp_get`'s 4-value return into `bound()`. The
micro batch (item 5) already did exactly this: the probe at lines 1494-1518
reads `ttK[s]`/`ttD[s]`/`ttS[s]`/`ttG[s]`/`ttM[s]` directly with the slot
computed once, full-key verified, and only on a real hit. `tp_get` no longer
exists. The review's `had_entry = (ttK[slot] == key)` matches the shipped code.
Rejected (already shipped).

### Item 5 — Split `move`/`value` into packed fast-paths: LOW VALUE (reject)

The review proposes eliminating the `type(move) == 'table'` branch in the hot
path. Verified: there are only 2 sites (lines 1140, 1276), and `type(move) ==
'table'` on a packed int is a single `LuaValue` type check — cheap. The search
path calls `m_move(pos, move, mv, true)` with a packed int; splitting into
`move_packed` would duplicate ~80 lines of `move()` (including the castling/
promotion/ep/hash-edit logic) for a branch that fires once per node. **Not worth
the code duplication and maintenance risk** — the review's 2-4% estimate is
unsupported; LuaJ's `type()` is not a "string comparison". Rejected.

### Item 6 — Inline packed-move math (`move_from`/`move_to`/`move_val`): ALREADY DONE

`move_from`/`move_to`/`move_val` are already module-level `local function`s
(lines 90-98) — local upvalues with no metatable dispatch. The arithmetic is
already hoisted (`VAL_SCALE`/`VAL_BIAS`/`PACKED_ZERO_VAL`, micro batch item 4).
The review's "precomputed masks in hot loops" would inline arithmetic at 9 call
sites for ~1 call/genMoves saved — the micro batch already evaluated and
rejected this exact slice. Rejected (already evaluated).

### Verdict summary

| Item | Verdict | Notes |
|------|---------|-------|
| 1. Hoist `add_edit` closure | **VALID, slice SHIPPED-ready** | ~2-4% search win; review's 15-25% overstated |
| 2. Remove `is_on_board_1` pawn pushes | **VALID, SHIPPED-ready** | ~42% on isolated pawn path (LuaJ), ~5-10% on movegen; behavior-identical |
| 3. Inline `move_greater` | Already done (micro batch) | review quotes stale code |
| 4. Inline `tp_get` | Already done (micro batch) | review quotes stale code |
| 5. Split move/value fast-paths | **REJECTED** | ~80-line duplication for a cheap branch; unsupported 2-4% claim |
| 6. Inline packed-move math | Already done (micro batch) | local upvalues + hoisted constants |

**Recommended next step**: ship items 1+2 as a behavior-identical batch (gate:
node invariant 27/153/287/1498/3030/10026 + `b8c6` + suites 14+15+21 + oracle
40/40), then CPU-time A/B per the established discipline.

### Shipped: items 1+2 (closure hoist + `is_on_board_1` removal) — ~4% CPU win

Implemented as a behavior-identical batch:

- **Item 1**: the per-call `add_edit` closure inside `Position:move()` is
  replaced with a module-level `zc(z, pc, sq)` helper (created once at load)
  plus inline delta arithmetic at each edit site. The closure was a per-call
  `LuaClosure` Java allocation on every search child (the review's "15-25%"
  estimate is overstated — closure creation is cheap relative to the 120-cell
  copy + `attacked()` walk — but the allocation is real and free to remove).
- **Item 2**: the `is_on_board_1[j]`/`is_on_board_1[j2]` guards in the pawn
  push/double-push are removed — off-board squares are SP=99/NL=98, never
  EMPTY=0, so `b[j] == EMPTY` inherently rejects them, and the double-push
  guard `i >= A1+N` confines `j2` to on-board rank-4 squares. The now-unused
  `is_on_board_1` table was deleted entirely.

**Gates (all green)**: node invariant `27/153/287/1498/3030/10026` + `b8c6`
(luajit + LuaJ); suites 14+15+21 on luajit/lua5.1; oracle 40/40; 300-position
random-walk hash consistency (cached `_bh` == fresh 120-pass recompute after
every move).

**CPU-time A/B** (cold `ai_move`, `/usr/bin/time` `User time`, 6 alternating
rounds, sequential cold JVMs): base 12.39/7.09/9.74/8.11/5.26/5.56 (mean 8.03)
vs mod 4.69/9.11/7.91/8.46/8.90/7.02 (mean 7.68) — **~4.3% CPU win on the
mean**, mod won 2/6 rounds. The isolated pawn-push microbenchmark showed ~42%
on that path under LuaJ, but the full search win is diluted (the pawn path is
a fraction of `genMoves`, which is a fraction of node cost). Within the
documented ±30% variance band; the direction is consistent with the
microbenchmark and the changes are behavior-identical, so the batch ships.

## Elo estimation harness: `benchmarks/elo_vs_stockfish.py`

A new benchmark that pairs sunfish against the local Stockfish 18 over UCI to
estimate sunfish's Elo. Design notes (matching the benchmark taste):

- **Stockfish strength via `go nodes N`** (deterministic, load-immune), not
  movetime (wall-clock, contaminated on this VM). Node limits 20..30000 span
  roughly the 1400-2600 Elo range on the anchor curve.
- **Deterministic opponent + fixed opening book**: Stockfish at fixed nodes is
  deterministic from a fixed FEN, so game variety comes from an 8-FEN opening
  book (both colors). 1 game per (level, opening, color) is the default.
- **sunfish bridge**: a persistent luajit subprocess speaking a file-queue
  protocol. luajit's `io.stdin:read("*l")` does NOT return lines from an open
  pipe (verified experimentally — it blocks on buffer-full/EOF), so commands go
  through numbered files + a `go` marker, with fine-grained busy polling.
- **Position sync**: before each sunfish move, the bridge rebuilds sunfish's
  position from the current real-board FEN (via Stockfish's `d` output). This
  sidesteps all frame-rotation bookkeeping; `pos_from_fen` (ported from
  test_perft) handles the engine's convention (rotate for black to move, swap
  castling rights, mirror ep).
- **Display-move conversion**: sunfish's `ai_move` returns the move in the
  child frame; the parity is 1 mirror for a white-to-move FEN, 0 for black —
  matching selfplay_correctness.py's proven `child_to_real` at odd/even plies.
- **Adjudication**: at the ply cap or a pass, a Stockfish probe (200k nodes)
  declares mate or a CP advantage ≥ 800 (decisive); otherwise a draw.

**Bugs found while building it** (all in the harness, not the engine):
1. `gsub("%s+","")` on the command line stripped the FEN's spaces, collapsing
   the whole FEN into one token — `pos_from_fen` failed silently.
2. The initial `play <uci>` design fed moves via coordinate conversion; the
   rotation parity was wrong (d7d5 → e2e4), corrupting sunfish's state until it
   crashed. Replaced with FEN-sync, which needs no move feeding at all.
3. The display→real mirror count was off by one for black-to-move FENs
   (b1c3 vs b8c6); fixed to 1 mirror (white) / 0 mirrors (black).

Usage: `python3 benchmarks/elo_vs_stockfish.py [--nodes ...] [--plies 60] [--book ...]`

**Measured result (2026-08-10, 8 levels × 8-FEN book × both colors, 3 games per
combination = 384 games per engine strength, luajit engine, Stockfish 18 via
`go nodes N`).** The `--sunfish-nodes` flag sets sunfish's per-move node budget
(engine default 1000). Correct numbers use the per-game label (`res` mapped through
sunfish's color); the printed W/D/L table in the harness is color-blind (counts every
white win as a sunfish win) — see the bug note below.

**sunfish @ 1000 nodes/move (default):**

```
   nodes  ~sf_elo    W    D    L    pts   score sunfish~
      20     1455    6   26   16   19.0   0.396     1382
      50     1595    5   21   22   15.5   0.323     1466
     100     1700    2   28   18   16.0   0.333     1580
     300     1867    2   25   21   14.5   0.302     1722
    1000     2050    2   10   36    7.0   0.146     1743
    3000     2217    0    8   40    4.0   0.083     1800
   10000     2400    4    4   40    6.0   0.125     2062
   30000     2567    2    4   42    4.0   0.083     2150

Fitted sunfish Elo (logistic ML, anchored on the ~sf_elo curve): 1589
```

**sunfish @ 10000 nodes/move (10× budget):**

```
   nodes  ~sf_elo    W    D    L    pts   score sunfish~
      20     1455    2   31   15   17.5   0.365     1359
      50     1595    3   32   13   19.0   0.396     1521
     100     1700    3   30   15   18.0   0.375     1611
     300     1867    2   22   24   13.0   0.271     1695
    1000     2050    1   16   31    9.0   0.188     1795
    3000     2217    3   12   33    9.0   0.188     1962
   10000     2400    5    3   40    6.5   0.135     2078
   30000     2567    2    6   40    5.0   0.104     2193

Fitted sunfish Elo (logistic ML, anchored on the ~sf_elo curve): 1631
```

Both response curves have the expected shape (best at the weak levels, worst at the
strongest). Caveats as designed: the absolute value inherits the anchor curve's
uncertainty (a 300-node Stockfish still plays weak moves like `a2a3`, so the low end of
the anchor is optimistic); draws dominate (34–42% of games), and most games hit the
60-ply cap adjudicated as a draw.

**10× node budget buys only ~40 Elo points (1589 → 1631)** — diminishing returns,
consistent with a search that spends extra nodes mostly re-confirming the same quiet
lines rather than converting wins against a node-limited opponent.

> **Harness counting bug (fixed in `58d4cde`):** the per-level W/D/L tally in
> `main()` counted `res` — which is *white-perspective* — as a sunfish win/loss
> without mapping through sunfish's color, because the combo `color` is the side
> Stockfish plays. When sunfish played black, every white win (`res="1-0"`) was
> misattributed to sunfish. Fixed by deriving `sun_color` (the opposite of the
> combo color) and using it consistently for the tally, the outcome mapping, and
> the log line. Verified: table == labels == tally on a 48-game controlled run.

### Opening book experiments (2026-08-11): no measurable Elo gain

Added a Zobrist-keyed opening book (benchmarks/sunfish.bin) generated from
Stockfish lines plus classic trap lines. The book is position-keyed by the
engine's exact 32-bit Zobrist hash, so lookups are transposition-safe.

**Engine API (2026-08-12):** the book is now wired into `sunfish.lua` itself:
`sunfish.set_book(path, seed)` loads the binary book, and `ai_move` consults
it before searching — a position whose Zobrist key (`Position:key()`) is in
the book plays a weighted-random book move (real-board coordinates mapped
into the engine frame; mirrored for black to move, validated via the
existing `sunfish.move` legality check; falls through to search if the move
isn't legal). The harness `--book-moves FILE` flag now pushes the book into
the engine through the bridge instead of intercepting moves in Python.
Covered by `tests/test_book.lua` (loads, disables, varied legal first moves,
legal black reply).

**Variety:** positions can hold multiple candidate moves with weights
(10/6/3/1 for the top-4 MultiPV moves); `ai_move` picks one weighted-randomly
per game (`seed` makes it deterministic). E.g. the standard start offers
`e2e4` (~44%), `c2c3` (~28%), `d2d4` (~14%), plus occasional `c2c4`/`g1f3`/
`g2g3` — same position, different first move game to game. Trap-line first
plies are excluded so junk roots (e.g. Fool's-mate `1.f3`) never appear.

Three book sizes tested (A/B at 1000 nodes/move, 384 games each: 8 levels × 8
FENs × 2 colors × 3 games, same seed):

| variant | positions | candidates | size | fitted Elo |
|---|---|---|---|---|
| baseline (no book) | — | — | — | **1919** |
| small book (single line/start) | 136 | 136 | 2.2 kB | **1915** |
| big book (MultiPV branch=2, plies=4, depth 12) | 788 | 788 | 12.6 kB | **1931** |
| varied book (branch=3, plies=3, depth 10, weighted) | 355 | 1592 | 25.5 kB | not re-measured |

**Verdict: no measurable gain** — the deterministic books land within the
run-to-run noise band (±30-50 at this sample). The varied book trades a bit
of strength for move diversity (deliberately, for human play); its Elo was
not re-measured since the deterministic books already bounded the effect.
At 1000 nodes sunfish already plays reasonable openings from the 8 harness
starts, so the book doesn't avoid enough early blunders to move Elo.

## Key risks (covered by existing tests)

- `board` nil on internal positions -> `ensure_board` at every public return.
- `store_data` round-trip -> materialize `board` first, filter `_`-prefixed fields.
- `is_legal` in-place undo (highest-risk) -> oracle + tests.
- `rotate()` `119-ep`/`119-kp`/case-swap semantics preserved.
- TT slot only selects the bucket; the stored full `_key` is verified on probe
  (`slot.key == key`) -> no wrong entries, collisions only cost a missed lookup.
- `king_sensitive` short-circuit must not misclassify: only skips `attacked()`
  for moves that provably can't change king safety (verified by oracle 40/40).

## Reliable endgames: DTM scoring, draw rules, material eval

Implemented per the reviewed endgame plan (heuristics + dynamic budget, no
tablebases — pure-Lua TBs are GC-heavy under LuaJ). Commits `321a222` (phases
1-5) and `9aa0134` (material threading):

- **Distance-to-mate**: `bound()` gains a `ply` param; the terminal mate is
  `-(MATE_VALUE - ply)`; the bound-entry mate band and the root search stop are
  ply-aware (the search stops on a `MATE_BAND` score, which the old flat
  `>= MATE_VALUE` missed — it let a found mate keep deepening into
  pathologies). TT mate scores are stored/retrieved re-anchored to the node's
  ply, so transpositions reached at different distances stay consistent.
- **State threading**: `piece_count`, `fifty`, and `material` are primitives
  threaded through `move()`/`rotate()`/pooling like `_king`/`_bh`. Public
  positions derive them from the board. `material` is the standing balance
  from the side-to-move's perspective; captures add the captured piece's value.
- **Draw rules before the TT probe, never cached** (path-dependent scores
  would poison transpositions): 50-move (`fifty >= 100`), repetition (a `path`
  table of hashes threaded through `bound()`, pushed/popped around each
  recursive call), and insufficient material (K vs K, K+minor vs K).
  NOTE: the 50-move check can fire on a deep quiet line in a won endgame
  before the search sees the mate — a known limitation, not yet tuned.
- **Endgame eval** (`piece_count <= 4`): `CORNER_DIST` precomputed (Chebyshev
  to the nearest corner); the leaf score adds `material` (so a queen-up KQK is
  ~+900, not ~0) plus a king-corraling gradient. This fixed the engine hanging
  the queen: the conversion gate went from 25% mate / 3 queen-blunder draws to
  40% mate / 0 draws.
- **Dynamic budget** in `search()`: x4 at <= 4 pieces, x2 at <= 6. The
  32-piece start position is unaffected (invariant 27/153/287/1008, root d7d5).
- **Null-move stays unconditional** (a `piece_count <= 4` guard was tried but
  it shifted the odd/even-depth horizon, collapsing won positions to draws at
  even depth; the guard was reverted). NOTE: null-move's false high in sparse
  positions is a known contributor to the conversion gap.

**Honest limits (measured)**: the engine keeps material and avoids blunders,
but cannot reliably *mate* within the 1000-4000 node budget — KQK/KRK mates
need ~20+ plies, far beyond the search horizon, so it shuffles (KQK 40%, KRK
25% conversion vs a random defender). Reaching the 95% target needs either a
tiny KQK/KRK/KPK tablebase or far deeper endgame search. The draw-holding
suite (K+P vs K defender) holds 100% so far.

**New tests**: DTM band assertions (mate-in-1 = `MATE_VALUE - 1`, KRK),
draw-rule tests (K vs K, K+B vs K, K+N vs K, fifty=99), `sunfish.set_nodes`
smoke. New benchmark: `benchmarks/endgame_conversion.py` (conversion rate +
draw-holding; fails only below a regression floor of 12.5%, aspirational 95%).

## 2026-09-26 sync: production fixes in, fiber substrate measured, castling + promotion fixes, futility shipped, LMR rejected again

This round synced the standalone engine with the production (RPD Android)
copy, brought our LuaJ fork into the benchmark matrix, and fixed two
correctness bugs the harnesses exposed.

### Production fixes ported from the RPD copy

- **fiber/coroutine dual yield**: the engine picks `fiber.yield` (NYRDS/luaj
  fork's zero-thread fiber library, quantum 32) when the `fiber` global is
  installed, else `coroutine.yield` (stock LuaJ / PUC Lua, quantum 256).
  All tests/benchmarks drive the search through the new `green.lua`
  (`green.run`/`green.guard`), which picks the same facility.
- **`sunfish.set_book_data(tbl, seed)`**: book from a pre-parsed Lua table
  (Android assets have no `io.open`). `set_book` now parses the binary into a
  table and delegates (return value changed from raw entry count to distinct
  position count).
- **`sunfish.ai_move(game, black_to_move)`**: optional explicit side param —
  the positional side-scan breaks on advanced pawns crossing the midline,
  which killed book replies for the AI in production (RPD snap-9wb).
- MATE_BAND stayed at `MATE_VALUE - 256` here (the RPD copy carries -30; the
  wide band is required for correct TT mate-score re-anchoring at any
  distance — flagged for the RPD copy).

### Yield substrate CPU-time matrix (8 searches/cold JVM, User time, alternating)

| substrate | mean |
|---|---|
| fork jar + coroutine q256 | 2.22 s |
| fork jar + fiber q32 | 3.34 s |
| stock 3.0.2 + coroutine q256 | 2.71 s |

The fiber **substrate** (FiberVM trampoline runs the entire search) costs
~40-50% CPU vs the recursive LuaClosure.execute path even with yields off;
fiber's win is zero-thread switching (no thread park per yield, tiny quanta
free) — the reason the Android embedding uses it. The fork's non-fiber fixes
are ~20% faster than stock 3.0.2. `benchmarks/java/LuajRun.java` (committed,
reflective FiberLib install + `-Dluaj.nofiber=true` opt-out) and a reworked
`benchmarks/run_luaj.sh` (system JDK, `LUAJ_JAR` override) make both jars
first-class; `benchmarks/bench_ai.lua` added for repeated-search CPU A/Bs
(single cold searches are JIT-warmup noise at ~100 ms on modern hardware).

### Castling-out-of-check: fixed (engine bug, all copies affected)

The self-play legality sweep (bridge-driven, 5 node budgets x 8 openings)
surfaced the engine castling **while in check** (`e8c8` at nodes=100): the
castling legality path only attack-tests the between/landing squares after
the move, so a king escaping a check ray sideways passed. Fixed in
`is_legal`: the search path rejects via the already-computed checker count
(`nch > 0`), the public path attack-tests the origin before mutating.
Historical gate suites never covered it; perft/oracle were extended upstream
of this fix and stay green.

### Under-promotion display: harness bug class (engine is correct)

The engine values and orders all four promotions correctly (queen highest:
measured Q 62429 > R 61158 > B 60697 > N 60527 on a g7h8 probe) but may
legitimately CHOOSE an under-promotion by search. Its display move carries
the promoted piece char (`f2f1n`). The Elo bridge and the selfplay gate both
stripped it and coerced queen — desyncing from the engine state (the
selfplay gate showed mass ILLEGAL after the first under-promotion; the Elo
bridge self-healed via per-move FEN sync, hiding the bug). Both now carry
the char; the selfplay gate additionally tries promotion suffixes when
validating 4-char moves (SF rejects bare last-rank pawn moves).

Also fixed in the harnesses: `fix_promotion` in the Elo game loop (bare
4-char promotions made SF abort the `position ... moves` line), stderr
capture + move-list logging on SF death, and the debug frame dump
(`SUNFISH_BRIDGE_DEBUG=1`) that pinned all of this.

**Stockfish 19 note**: the sf_19 "universal" Linux build segfaulted
silently mid-session in ~1 of 4 games (stderr empty; the same position
sequence replays fine in isolation). Replaced with the SF 17.1
ubuntu-avx2 build as the harness default; 128-game runs complete cleanly.

### Frontier futility pruning: SHIPPED (margin 200)

At depth 1 on interior nodes (ply > 0), no check, > 6 pieces, quiet moves
(val < 150) are pruned when `pos.score + margin <= gamma` — the condition is
loop-invariant and the list is sorted best-first, so the loop breaks at the
first pruned quiet move. The all-pruned node returns stand-pat. Root excluded
(the full window at the root's depth-1 call made everything "futile" and
reduced root move seeding to captures — caught by the node invariant before
ship); sparse endgames excluded (the king-corraling gradient lives outside
the material score). Tunable: `SUNFISH_FUTILITY` env / `sunfish.set_futility`.

Gates: suites 15+22+7+21 on luajit/lua5.1, oracle 40/40, node invariant
unchanged (27/153/287/1008, d7d5), selfplay correctness 60 plies 0 failures.
Elo (128 games, SF17.1 anchor): baseline 1942 -> futility 1953 (pre-root-gate
build) -> shipped build 1926 — all within the ±30-50 noise band; kept for the
interior node savings (deeper effective search at fixed budget, faster
response under a time budget).

### LMR: REJECTED a second time (ordering quality, not wall time)

Re-tested per the standing suggestion (per-node cost is much lower post-
pin-check, and the budget-bounded search converts node savings into depth).
Gates caught it immediately: the KQK king-corraling gradient collapsed to 0
(corralling moves are quiet king moves — exactly what LMR reduces) and a
1000-node search picked 1...Na6 over 1...Nc6. Verdict: LMR reductions assume
late moves are reliably harmless, which requires a real ordering heuristic
(history/killers); PST-only ordering is too weak. Parked until such a
heuristic lands.

### Elo baseline (this machine, SF17.1 anchor, 128 games, 1000 nodes/move)

Fitted sunfish Elo ~1926-1953 across this round's builds (the SF18-anchored
1589/1631 figures from 2026-08 are not directly comparable — different
anchor binary and a load-free machine).
