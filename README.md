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

## Running

```sh
# Tests
lua tests/test_sunfish.lua        # or: lua5.1, luajit

# Benchmarks
luajit benchmarks/bench_sunfish.lua
```

## Notes on the engine's API (verified by the tests)

- **Rotation semantics**: the engine rotates the board after every move. `sunfish.move`
  takes coordinates in the frame of the *current* position. When it is Black's turn,
  enter the move as White would in the rotated view (e.g. after `e2e4`, Black's `e7e5`
  is entered as `e2e4` again).
- **`ai_move` returns a display move** in the rotated (Black) frame, so it will not
  necessarily replay through `sunfish.move` on the same position. It is meant to be
  shown to the user, not fed back into `move`.
- **Search must run inside a coroutine**: `search`/`bound` call `coroutine.yield()`
  every 30 nodes. Call `ai_move` from a coroutine (the test harness does this; so does
  the benchmark). Calling it at top level raises "attempt to yield across C-call
  boundary".
- **Global transposition table**: the TT is module-level and never cleared, so repeated
  `ai_move` calls in one process become progressively slower (measured ~0.4s, 1.1s,
  6.7s for the first three searches). The tests keep `ai_move` usage light and the
  harness gives each test a 30s budget.
- **`sunfish.move` with non-string input** (e.g. `nil`) will raise, not return `false`.
  Only string moves are validated.
