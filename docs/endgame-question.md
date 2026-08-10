# Question for a stronger AI: how to continue making endgames reliable in sunfish.lua

## Context: what sunfish.lua is

A from-scratch Lua chess engine (a transpilation of
https://github.com/thomasahle/sunfish) that targets **LuaJ 3.0.2 interpreter
mode on Android** as its deployment runtime (NOT LuaJIT, NOT luajc). The whole
codebase is one file, `sunfish.lua` (~2150 lines), plus a test suite in
`tests/` and benchmarks in `benchmarks/`. The engine rotates the board 180
degrees after every move (the "sunfish trick"): pieces of the side to move are
always uppercase codes 1..6, enemy pieces are negatives, and the 120-char
board string is indexed 1-based (A1=92, H1=99, A8=22, H8=29, padding squares
are 98/99).

Search is a **MTD(f)-style fail-soft alpha-beta with a negamax `bound()`**:
`bound(pos, gamma, depth, maxn, ply, path)` — `ply` is the distance from the
root (distance-to-mate scoring), `path` is a table of Zobrist hashes on the
current line (repetition detection). A fixed 64k-slot transposition table
(five parallel arrays, sum-based Zobrist keys, no bit32), null-move pruning
(R=3, `depth - 3`), move ordering via piece-square-table move values (sorted
by a count-driven in-place heap sort), F3 root aspiration (±100, binary-search
window with full-window fail-widen re-search), and a hard node budget
`NODES_SEARCHED = 1000` per move by default (runtime-tunable via
`sunfish.set_nodes`; the search aborts mid-depth when the budget is exhausted
and keeps the last completed depth's fail-high move). It runs inside a
coroutine and yields every 256 nodes.

## What has been implemented (commits 321a222, 9aa0134, 9e32387)

All of this is in the current `master`, gates green on luajit + lua5.1.

1. **Distance-to-mate scoring** (`MATE_BAND = MATE_VALUE - 256`):
   - Terminal mate returns `-(MATE_VALUE - ply)`; negamax negation propagates
     DTM up the tree.
   - Bound-entry early-out is ply-aware
     (`pos.score >= MATE_VALUE - ply`), and the **root search stops on a
     `MATE_BAND` score** — the old flat `>= MATE_VALUE` never fired for DTM
     and let a found mate keep deepening into pathologies (a real bug found
     and fixed).
   - TT mate scores are stored/retrieved re-anchored to the node's ply
     (`tt_score ± ply` in the band), so transpositions reached at different
     distances stay consistent.
   - No aspiration special-case was needed: the F3 fail-widen full-window
     re-search already handles mate-band scores correctly.

2. **State threading**: `piece_count`, `fifty`, and `material` are primitives
   threaded through `move()`/`rotate()`/pooling exactly like the existing
   `_king`/`_bh`/`_mh`/`_fh`. Public positions derive them from the board.
   `material` is the standing material balance from the side-to-move's
   perspective (PIECE_VAL: P=100, N=320, B=330, R=500, Q=900); captures add
   the captured piece's value; rotation flips the sign.

3. **Draw rules**, checked **before** the TT probe and **never written to the
   TT** (path-dependent scores would poison transpositions):
   - 50-move: `pos.fifty >= 100` → 0.
   - Repetition: `path` table of hashes, pushed/popped around each recursive
     `bound()` call (including the null move); a hash match on the line → 0.
   - Insufficient material: K vs K, K+B vs K, K+N vs K → 0 (a board scan,
     only when `piece_count <= 3`).

4. **Endgame eval** (only when `piece_count <= 4`): a leaf-return
   `pos.score + endgame_eval(pos)` where `endgame_eval` adds the threaded
   `material` (so a queen-up KQK is ~+900, not ~0) plus a king-corraling
   gradient: `-10 * CORNER_DIST[enemy_king] - 2 * king_king_chebyshev`.
   `CORNER_DIST[1..120]` is precomputed at load (Chebyshev distance to the
   nearest corner). This fixed the engine hanging the queen.

5. **Dynamic node budget** in `search()`: ×4 at `piece_count <= 4`, ×2 at
   `<= 6`. The 32-piece start position is unaffected (invariant holds).

6. **Null-move stays unconditional** (a `piece_count <= 4` guard was tried
   and reverted — it shifted the odd/even-depth horizon, collapsing won
   positions to draws at even depth).

7. **Validation harness** (`benchmarks/endgame_conversion.py`): random KQK/KRK
   positions vs a random legal defender (conversion rate) plus a KPK
   draw-holding suite (sunfish defends a pawn blockade). Gates:
   `tests/test_sunfish.lua` (15), `tests/test_endgames.lua` (22 — DTM band
   assertions, draw rules, mate-in-1/2), `tests/test_perft.lua` (21, all
   standard), `benchmarks/verify_invariant.lua` (27/153/287/1008, root d7d5),
   `tests/compare_python_chess.py` (40/40), `benchmarks/selfplay_correctness.py`
   (Stockfish-validated selfplay).

## Measured results and the remaining gap

- **Conversion** (winning side vs a random defender, 40-60 ply cap): KQK **40%**
  mate (was 25% before material threading, with 3 queen-blunder draws → now 0),
  KRK **25%**.
- **Draw-holding** (K+P vs K defender): **100%** held so far.
- **The gap**: the engine reliably keeps its material and avoids blunders, but
  **cannot reliably *mate***. KQK/KRK mates need ~20+ plies, far beyond the
  search horizon at 1000-4000 nodes, so the engine shuffles (making progress
  via the corner gradient, but the defender shuffles away). Depth parity is a
  factor: at even search depth the side-to-move-at-leaves is the one who can
  capture the extra piece, and the horizon makes the win look drawable — both
  with and without null-move there are collapsing depths.
- **Known caveats**: the 50-move check can fire on a deep quiet line in a won
  endgame before the search sees the mate (not yet tuned); the null-move false
  high in sparse positions is a known contributor.

## What we want from you: continuation

Please design the next concrete step to close the conversion gap, within the
constraints (pure Lua 5.1 arithmetic, no bit32, LuaJ interpreter performance
matters, single-file engine, all gates stay green). Specifically weigh:

1. **Small endgame tablebase (KQK, KRK, KPK)** as in-memory lookup tables
   (no external files): KQK/KRK/KPK are fully solvable with tiny tables.
   Pure-Lua bitboards + index math are viable at 3-4 pieces; how would you
   structure the tables, the probing, and the score/DTM integration with the
   existing search (probe at the root / at leaves / in `is_legal`-adjacent
   code)? Memory and build-time are real constraints under LuaJ.
2. **Deeper endgame search**: what selective mechanism would actually find a
   20-ply KQK mate at 4k-40k nodes — check extensions (tried, no measurable
   gain), capture extensions, quiescence, mate-distance pruning, or
   search extensions on the cornering net? What is the honest cost/benefit
   vs the tablebase?
3. **Search-integrity fixes**: the depth-parity collapses (even-depth
   "queen is lost" vs odd-depth "queen is safe") and the 50-move-in-search
   caveat. Is there a correct way to handle these (e.g. only apply 50-move at
   the root, mate-distance-aware TT replacement, zugzwang-safe null-move)?
4. **Better validation**: is the conversion-rate-vs-random-defender metric
   the right oracle, or should we move to Stockfish-verified mate-in-N suites
   (fixed positions with known DTM) that directly test the mating gradient?

## What was tried (and reverted): the KQK/KRK DTM tablebase generator

An offline retrograde DTM generator (`benchmarks/gen_endgame_tb.py`) was
attempted per the root-only microtablebase design (byte-string tables, index
`sk64*4096 + wk64*64 + pc64`, values 0..120 DTM / 250 draw, probed only at
the root, never touching the TT or `bound()`). It is NOT committed — the
generator produced a wrong table and was removed; the working tree is back at
the last green state.

**What worked:**
- The table design and the move tables (king/slider moves per square,
  capture-legality: the weak king may not capture an adjacent-defended piece,
  self-check rules) are correct.
- The mated-state seeding is verified: `Kf6 Qg7 vs Kh8` (weak to move,
  checkmated) returns DTM 0.

**What failed:** the retrograde propagation resolves only the 16 mate-in-1
strong states, then stalls — the full closure to DTM 2, 3, ... never happens.
Four different retrograde formulations were tried and all stalled identically
(queue + unknown-child countdown; done-flag variants with draw-child
propagation; iterative-layer expansion with per-pass count recompute). Every
one resolved the same 16 DTM-1 states and nothing deeper, and no weak state
ever had all its strong children resolved. The identical failure across four
independent formulations points to a bug in the **child-graph structure
itself** (weak-to-move child encoding or reverse-adjacency direction), not in
the propagation loop. Root-cause debugging was not completed.

**Recommendation for whoever picks this up:** before trusting any retrograde,
validate the child graph against python-chess's legal moves on a small sample
(e.g. 100 random states per side: does `children()` produce exactly the legal
moves with correct child IDs, and does every strong state have at least one
weak parent via the reverse adjacency?). The Lua-side probe design (SQ64,
recognize_tb, tb_root_move, the fifty-move guard, no-TT-touching) is fully
independent of the generator and ready to implement once a correct table
exists.

## Constraints and current architecture (all verified against the code)

- **Runtime**: LuaJ 3.0.2 interpreter on Android. No bit32, no bitwise
  operators, no luajc. Pure Lua 5.1 arithmetic (`math.floor`, `%`, `2 ^ n`).
  Every per-node allocation and function call is measured and matters.
- **Search**: `bound(pos, gamma, depth, maxn, ply, path)`. Terminal:
  `nlegal == 0` → `-(MATE_VALUE - ply)` (mate) or `0` (stalemate). No
  quiescence, no extensions beyond the (reverted) check extension, no
  reductions beyond null-move.
- **Node budget**: `NODES_SEARCHED = 1000` default; dynamic ×4 (≤4 pieces)
  / ×2 (≤6) in `search()`. Tunable via `sunfish.set_nodes(n)`.
- **Eval**: `Position:value(move, b)` = PST deltas + captured piece value +
  castling/kp terms + promotion bonus (move ordering). The static score at
  leaves for `piece_count <= 4` is `pos.score + material + corner gradient`
  (see above). No positional evaluation beyond the corner gradient.
- **Position model**: 120-cell 1-based board array `_b`; rotation is
  `nb[k] = (v==98 or v==99) and v or -v` from `b[121-k]`. King indices
  (`_king`/`_eking`), dual Zobrist hashes (`_bh`/`_mh`/`_fh`), `piece_count`,
  `fifty`, and `material` are threaded through `move()`/`rotate()` so `key()`
  is O(1) on the search path.
- **Draw state**: `fifty` (half-move clock), `path` (repetition hashes),
  `insufficient_material()` — all live, pre-TT, never cached.
- **Gates** (all green on luajit + lua5.1): test_sunfish (15), test_endgames
  (22), test_perft (21, all standard), verify_invariant (27/153/287/1008, root
  d7d5), compare_python_chess (40/40), selfplay_correctness (40+ plies, 0
  illegal), endgame_conversion (regression floor 12.5%, aspirational 95%).

## What we are NOT asking

- Not asking for tablebase integration with external files (must stay
  single-file self-contained Lua; in-memory generated tables are fine).
- Not asking for a general eval rewrite (that's a separate thread).
- Not asking for an ELO-blasting search overhaul; the question is specifically
  about closing the endgame conversion gap — convert wins, hold draws, avoid
  stalemate traps, score mates correctly — within the existing architecture.

Please respond with a prioritized, concrete plan: what to build next, the
exact mechanics (tablebase layout/probing or search-extension rules) with
edge cases (TT mate-score pitfalls, repetition-in-TT, aspiration window
interaction, depth parity), and how to validate each step against the gates
above. Where there are tradeoffs (tablebase vs deeper search vs better eval
terms), give a recommendation with reasoning.
