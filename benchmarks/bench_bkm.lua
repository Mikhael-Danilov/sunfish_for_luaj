-- benchmarks/bench_bkm.lua
-- Benchmark the bkm.lua KRK/KQK endgame solver: table build, evaluate, best_move.
--
-- Usage: luajit benchmarks/bench_bkm.lua  (or lua5.1, lua)
-- Honors BENCH_SCALE (0..1) to shrink iteration counts for slow interpreters.

local scale = tonumber(os.getenv("BENCH_SCALE")) or 1

local bkm = require("bkm")

local function timeit(fn)
  local t0 = os.clock()
  fn()
  return os.clock() - t0
end

print(string.format("%-28s %12s %12s", "operation", "lua5.1-style", "per-op"))
print(string.rep("-", 56))

for _, piece in ipairs({ "R", "Q" }) do
  local build = timeit(function()
    bkm.solver(piece)
  end)
  print(string.format("%s build (first call)     %10.2f s", piece, build))

  local sol = bkm.solver(piece)

  -- evaluate throughput: full-table scan via evaluate (decode + status + dtm)
  local n = math.floor(524288 * scale)
  local t = timeit(function()
    for i = 1, n do
      local wk, pc, bk, stm = sol.decode(i)
      sol:evaluate(wk, pc, bk, stm)
    end
  end)
  print(string.format("%s evaluate x%-8d     %10.3f s   %8.0f/s", piece, n, t, n / t))

  -- best_move throughput: fixed positions, strong to move
  local moves_n = math.floor(200000 * scale)
  local pos = { wk = 41, pc = 7, bk = 56, stm = 0 } -- Kb6 Rh1 vs Ka8
  if piece == "Q" then pos.pc = 54 end
  local t2 = timeit(function()
    for _ = 1, moves_n do
      sol:best_move(pos)
    end
  end)
  print(string.format("%s best_move x%-8d    %10.3f s   %8.0f/s", piece, moves_n, t2, moves_n / t2))

  -- mixed weak/strong best_move
  local t3 = timeit(function()
    for i = 1, moves_n do
      local stm = i % 2
      sol:best_move { wk = 41, pc = 7, bk = 56, stm = stm }
    end
  end)
  print(string.format("%s best_move mixed x%-6d %10.3f s   %8.0f/s", piece, moves_n, t3, moves_n / t3))
end
