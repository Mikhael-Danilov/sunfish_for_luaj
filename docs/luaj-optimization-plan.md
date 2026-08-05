# sunfish.lua — Optimization Plan for LuaJ Interpreter Mode (Android)

## Status

- [x] Phase 1: Signed-int board core + lazy sync — **DONE**
- [ ] Phase 2: Precomputed attack/ray tables
- [ ] Phase 3: TT: cached key + fixed-size probe table
- [ ] Phase 4: Search micro-opts

### Phase 1 results (measured, BENCH_SCALE=0.05 LuaJ)

| Benchmark | Baseline | Phase 1 | Delta |
|-----------|----------|---------|-------|
| `ai_move` (full search) | 34.5 s | 19.5 s | **1.8x faster** |
| `new` | 7.0k/s | 14.5k/s | 2.1x |
| `move (e2e4)` | 208/s | 272/s | 1.3x |
| illegal `move` | 512/s | 911/s | 1.8x |
| store/restore | 12.8k/s | 5.4k/s | 0.42x (slower - builds string) |

Also faster on luajit (`ai_move` 2.78s -> 0.54s) and lua5.1 (5.4s -> 3.8s).
All tests green on luajit/lua5.1/LuaJ (14 main + 15 endgame) + oracle 40/40.

### Phase 1 notes

- Piece codes `0,1..6,-1..-6,98,99`; `N` knight renamed `KN` to avoid the
  direction constant `N=-10`.
- `_b` int array lazy-synced with `board` string; `ensure_board()` at public
  boundaries (sunfish.move/ai_move/store_data).
- `is_legal` now mutates `_b` in place + undoes (castling replicates the
  original construction quirk: king at `between`, rook at `j`, origin untouched).
- `rotate()`/`move()` are single 120-pass array builds (no string ops).
- Known follow-ups: store/restore regression (string materialize), legal move
  still builds `board` per `sunfish.move` call, TT still string-concats per node.

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

## Phases

| # | Step | Est. LuaJ gain | Risk |
|---|------|----------------|------|
| 1 | Signed-int board core + lazy sync | 2-4x | Med-High (sync invariants) |
| 2 | Precomputed attack/ray tables | 1.2-1.6x | Low-Med |
| 3 | TT: cached key + fixed-size probe table | 1.2-1.5x + fixes 0.4->6.7s degradation, bounds memory | Med |
| 4 | Search micro-opts (in-place move filter, hoisted sorter, cached king, yield counter) | 1.1-1.3x | Low |

Cumulative target: **~21s -> 3-5s** per `ai_move` under LuaJ.

## Validation per phase

- `luajit` + `lua5.1` run `tests/test_sunfish.lua` (14) and
  `tests/test_endgames.lua` (15) — all green.
- `python3 tests/compare_python_chess.py` — 40/40 legal-move oracle.
- `TEST_BUDGET=120 benchmarks/run_luaj.sh tests/test_sunfish.lua` under LuaJ.
- `BENCH_SCALE=0.01 benchmarks/run_luaj.sh` — record `ai_move` ms / `move` iter/s.

## Android specifics

- Pure Lua 5.1 source: no luajc, no bcel, no bit32, no FFI.
- Fixed-size TT (~64k slots) replaces the unbounded 1e6-entry dict -> bounded ~10MB.
- `YIELD_INTERVAL`, `TT_SIZE`, `NODES_SEARCHED` exposed as tunables.
- Search `print` gated behind `SUNFISH_VERBOSE`.

## Key risks (covered by existing tests)

- `board` nil on internal positions -> `ensure_board` at every public return.
- `store_data` round-trip -> materialize `board` first, filter `_`-prefixed fields.
- `is_legal` in-place undo (highest-risk) -> oracle + tests.
- `rotate()` `119-ep`/`119-kp`/case-swap semantics preserved.
- TT `_h` only selects the slot; stored `_key` verified -> no wrong entries.
