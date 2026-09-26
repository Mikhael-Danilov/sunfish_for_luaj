-- benchmarks/selfplay.lua
-- Same-game paired self-play timing harness for sunfish.lua.
--
-- The engine plays both colors by rotating after every move (one engine is
-- both sides). To reconstruct the actual chess move at each ply we diff the
-- parent board from the child board: ai_move returns the *rotated* child, so
-- the piece that moved appears as its own-color mirror on the mirrored square.
--
-- Usage (paired protocol): run this same script for the BASELINE engine and
-- the MODIFIED engine (two checkouts / two sunfish.lua copies), requiring
-- byte-identical move sequences so per-ply timings are comparable:
--
--   benchmarks/run_luaj.sh benchmarks/selfplay.lua <engine_dir> <plies> <label>
--
-- where <engine_dir> is a directory containing sunfish.lua (default: repo root).
-- Output: per-ply "move score ms" lines plus a total; the paired runner
-- (ab_luaj.sh) aggregates the totals across >= 5 games and reports the median.
--
-- Set SUNFISH_NO_YIELD=1 to disable the search coroutine's periodic yields
-- (uncapped throughput ceiling; matches the benchmark's methodology).

local plies = tonumber(arg[2]) or 40
local label = arg[3] or ("plies=" .. plies)
local engine_dir = arg[1]

if engine_dir then
    package.path = engine_dir .. "/?.lua;" .. package.path
end

-- Disable yields for pure timing (the A/B compares uncapped engine speed).
if os.getenv("SUNFISH_NO_YIELD") == "1" then
    local sf0 = require("sunfish")
    sf0.set_yield(nil, false)
end

local sunfish = require("sunfish")
local green = require("green")

-- Drive ai_move from a coroutine (the engine yields during search).
local function ai_move(game)
    return green.run(function() return sunfish.ai_move(game) end)
end

local function now_ms()
    return os.clock() * 1000
end

-- ai_move returns the display move `mv` in the CURRENT (pre-move) frame:
--   render(119 - move_from(move)) .. render(119 - move_to(move))
-- so mv IS the actual chess move from the position before ai_move. No board
-- diff is needed.

local game = sunfish.new()
local total_ms = 0
local prev_ms = now_ms()
local last_ply = 0

for ply = 1, plies do
    local ng, mv, sc = ai_move(game)
    local t = now_ms() - prev_ms
    prev_ms = now_ms()
    total_ms = total_ms + t
    last_ply = ply

    -- ai_move may return nil at the root when the module-level TT entry is
    -- overwritten by a deeper transposition; the engine passes. Report (pass).
    if not mv then
        print(string.format("%s ply %2d  (pass)  score %d  %7.1f ms", label, ply, sc or 0, t))
    else
        print(string.format("%s ply %2d  %s  score %d  %7.1f ms", label, ply, mv, sc or 0, t))
    end
    game = ng

    -- Stop early on mate/stalemate (score at the boundary).
    if sc and math.abs(sc) >= sunfish.MATE_VALUE then
        break
    end
end

print(string.format("%s TOTAL %7.1f ms over %d plies", label, total_ms, last_ply))
