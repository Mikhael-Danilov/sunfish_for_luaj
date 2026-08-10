-- benchmarks/bench_bkm_light.lua
-- Compare bkm_light.lua (heuristic mover) vs bkm.lua (exact retrograde solver):
--   * build/init cost
--   * memory footprint
--   * best_move throughput (strong + weak)
--   * mate quality: self-play games from random positions (mated, plies-to-mate)
--
-- Usage: luajit benchmarks/bench_bkm_light.lua [games] [seed]
-- Honors BENCH_SCALE to shrink iteration counts.

local scale = tonumber(os.getenv("BENCH_SCALE")) or 1
local games = tonumber(arg[1]) or math.floor(400 * scale)
local seed = tonumber(arg[2]) or 1

local bkm = require("bkm")
local bkm_light = require("bkm_light")

local function timeit(fn)
  local t0 = os.clock()
  fn()
  return os.clock() - t0
end

collectgarbage("collect")
local function mem()
  collectgarbage("collect")
  return collectgarbage("count")
end

print("== bkm_light vs bkm ==")
print()

---------------------------------------------------------------
-- Build / memory
---------------------------------------------------------------
local m0 = mem()
local sol_exact = bkm.solver("R")
local m1 = mem()
print(string.format("bkm.lua solver R build:        %8.3f s   mem delta %6.0f KB", timeit(function() bkm.solver("R") end), m1 - m0))

local m2 = mem()
local light = bkm_light
local m3 = mem()
print(string.format("bkm_light.lua require:         %8.3f s   mem delta %6.0f KB", timeit(function() require("bkm_light") end), m3 - m2))

---------------------------------------------------------------
-- best_move throughput (fixed position, strong to move)
---------------------------------------------------------------
local moves_n = math.floor(20000 * scale)
local posR = { wk = 41, pc = 7, bk = 56, stm = 0 }   -- Kb6 Rh1 vs Ka8
local posQ = { wk = 41, pc = 54, bk = 56, stm = 0 }  -- Kb6 Qh6? pc=54 -> g7

local t = timeit(function()
  for _ = 1, moves_n do sol_exact:best_move(posR) end
end)
print(string.format("exact R  best_move x%-7d  %8.3f s  %8.0f/s", moves_n, t, moves_n / t))

local t = timeit(function()
  for _ = 1, moves_n do bkm_light.best_move(posR, "R", { mate_plies = 1 }) end
end)
print(string.format("light R  best_move x%-7d  %8.3f s  %8.0f/s  (mate_plies=1)", moves_n, t, moves_n / t))

local t = timeit(function()
  for _ = 1, moves_n do bkm_light.best_move(posR, "R", { mate_plies = 3 }) end
end)
print(string.format("light R  best_move x%-7d  %8.3f s  %8.0f/s  (mate_plies=3)", moves_n, t, moves_n / t))

-- mixed weak/strong
local t = timeit(function()
  for i = 1, moves_n do
    local stm = i % 2
    sol_exact:best_move { wk = 41, pc = 7, bk = 56, stm = stm }
  end
end)
print(string.format("exact R  best_move mixed   %8.3f s  %8.0f/s", t, moves_n / t))

local t = timeit(function()
  for i = 1, moves_n do
    local stm = i % 2
    bkm_light.best_move({ wk = 41, pc = 7, bk = 56, stm = stm }, "R", { mate_plies = 1 })
  end
end)
print(string.format("light R  best_move mixed   %8.3f s  %8.0f/s", t, moves_n / t))

---------------------------------------------------------------
-- Mate quality: self-play from random legal positions
---------------------------------------------------------------
local rng = { x = seed }
function rng:next(m)
  self.x = (self.x * 1664525 + 1013904223) % 4294967296
  return math.floor(self.x / 65536) % m
end

local adj = {}
for a = 0, 63 do
  adj[a] = {}
  local af, ar = a % 8, math.floor(a / 8)
  for b = 0, 63 do
    local bf, br = b % 8, math.floor(b / 8)
    if math.max(math.abs(af - bf), math.abs(ar - br)) <= 1 then adj[a][b] = true end
  end
end

local function attacked_by_piece(piece, pc, target, blocker)
  if pc == target then return false end
  local pf, pr = pc % 8, math.floor(pc / 8)
  local tf, tr = target % 8, math.floor(target / 8)
  local df, dr = tf - pf, tr - pr
  local adf, adr = math.abs(df), math.abs(dr)
  local ok
  if piece == "R" then ok = (df == 0 or dr == 0)
  else ok = (df == 0 or dr == 0 or adf == adr) end
  if not ok then return false end
  local sf = (df > 0 and 1) or (df < 0 and -1) or 0
  local sr = (dr > 0 and 1) or (dr < 0 and -1) or 0
  local f, r = pf + sf, pr + sr
  while f ~= tf or r ~= tr do
    if r * 8 + f == blocker then return false end
    f = f + sf
    r = r + sr
  end
  return true
end

local function sample_state(piece)
  for _ = 1, 2000 do
    local wk = rng:next(64)
    local bk = rng:next(64)
    local pc = rng:next(64)
    if not adj[wk][bk] and pc ~= wk and pc ~= bk
      and not attacked_by_piece(piece, pc, bk, wk) then
      return wk, pc, bk
    end
  end
  return nil
end

local function legal_pos(wk, pc, bk)
  return wk ~= pc and wk ~= bk and pc ~= bk
    and math.max(math.abs(wk % 8 - bk % 8), math.abs(math.floor(wk / 8) - math.floor(bk / 8))) > 1
end

-- Play a game with the given mover; returns plies-to-termination or nil if
-- it does not terminate within max_plies.
local function play_game(piece, mover, max_plies, mate_plies)
  local wk, pc, bk = sample_state(piece)
  local stm = rng:next(2)
  local pos = { wk = wk, pc = pc, bk = bk, stm = stm }
  local ply = 0
  while ply < max_plies do
    local mv
    if mover == "light" then
      mv = bkm_light.best_move(pos, piece, { mate_plies = mate_plies })
    else
      mv = sol_exact:best_move(pos)
    end
    if not mv then
      -- terminal: mate if weak in check, else stalemate (draw)
      return ply, attacked_by_piece(piece, pos.pc, pos.bk, pos.wk)
    end
    local f, t = mv.from, mv.to
    if pos.stm == 0 then
      if mv.piece == "K" then pos.wk = t else pos.pc = t end
    else
      pos.bk = t
    end
    pos.stm = 1 - pos.stm
    ply = ply + 1
    if mv.capture then
      return ply, false  -- captured piece: draw
    end
    if not legal_pos(pos.wk, pos.pc, pos.bk) then
      return ply, false
    end
  end
  return nil, false
end

for _, piece in ipairs({ "R", "Q" }) do
  for _, mover in ipairs({ "exact", "light" }) do
    local mated = 0
    local drawn = 0
    local nonterm = 0
    local plies_sum = 0
    for g = 1, games do
      local ply, is_mate = play_game(piece, mover, 200, 1)
      if ply == nil then
        nonterm = nonterm + 1
      elseif is_mate then
        mated = mated + 1
        plies_sum = plies_sum + ply
      else
        drawn = drawn + 1
      end
    end
    local avg = mated > 0 and string.format("%.1f", plies_sum / mated) or "-"
    print(string.format("%s %s: games=%d mated=%d drawn=%d nonterm=%d avg_plies=%s",
      piece, mover, games, mated, drawn, nonterm, avg))
  end
end
