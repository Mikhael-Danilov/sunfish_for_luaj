-- benchmarks/bench_ai.lua — repeated start-position ai_move searches for
-- CPU-time A/B under LuaJ (the single cold search in bench_sunfish.lua is
-- dominated by JIT warmup at ~100ms/search on fast machines).
--
-- Usage: benchmarks/run_luaj.sh benchmarks/bench_ai.lua [n_searches]
--   AI_ITERS=8 BENCH_SCALE=... benchmarks/run_luaj.sh benchmarks/bench_ai.lua
--
-- The module TT persists between searches (as in a real game), so every
-- variant sees the same JIT-warmup + TT-growth profile. Search 1 is JIT
-- warmup; the summary reports the steady-state mean over the rest. Pair with
-- `/usr/bin/time -v` User time over the whole JVM for the reliable signal.
local sunfish = require("sunfish")
local green = require("green")

local n = tonumber((...)) or tonumber(os.getenv("AI_ITERS")) or 8

local times = {}
for i = 1, n do
    local t0 = os.clock()
    green.run(function()
        local g = sunfish.new()
        local ng, mv = sunfish.ai_move(g)
        if not mv then
            error("ai_move returned no move on search " .. i)
        end
    end)
    local dt = (os.clock() - t0) * 1000
    times[i] = dt
    print(string.format("search %d: %.1f ms", i, dt))
end

local total = 0
local steady = 0
for i = 1, n do
    total = total + times[i]
    if i > 1 then steady = steady + times[i] end
end
if n > 1 then
    print(string.format("TOTAL %.1f ms  steady-mean %.1f ms (searches 2..%d)",
        total, steady / (n - 1), n))
else
    print(string.format("TOTAL %.1f ms", total))
end
