-- benchmarks/bench_sunfish.lua
-- Benchmarks for sunfish.lua's public API.
-- Run: luajit benchmarks/bench_sunfish.lua   (or lua / lua5.1)

local sunfish = require("sunfish")
local green = require("green")

local function now_ms()
    return os.clock() * 1000
end

local function bench(name, iters, fn)
    collectgarbage("collect")
    local t0 = now_ms()
    for i = 1, iters do
        fn(i)
    end
    local dt = now_ms() - t0
    print(string.format(
        "  %-38s %8d iters  %10.2f ms  %10.1f iter/s",
        name, iters, dt, dt > 0 and (iters / dt * 1000) or math.huge))
    return dt
end

-- Runs a function inside a coroutine (the engine's search yields periodically).
local function in_coroutine(fn)
    green.run(fn)
end

print(string.format("Lua: %s", _VERSION))
print(string.format("sunfish.MATE_VALUE = %d\n", sunfish.MATE_VALUE))

-- Iteration scale for slow interpreters (e.g. LuaJ). Set BENCH_SCALE=0.01 to
-- run 1/100th of the iterations, keeping runtime proportional.
local scale = tonumber(os.getenv("BENCH_SCALE")) or 1
if scale <= 0 or scale > 1 then scale = 1 end
local function N(n)
    return math.max(1, math.floor(n * scale))
end

local game = sunfish.new()

-- 1. Position lifecycle
bench("sunfish.new", N(100000), function()
    sunfish.new()
end)

bench("sunfish.move (e2e4)", N(20000), function()
    sunfish.move(game, "e2e4")
end)

bench("store_data / restore_data round-trip", N(50000), function()
    local d = sunfish.store_data(game)
    sunfish.restore_data(d)
end)

-- 2. Coordinate conversion
bench("move_2_cell", N(1000000), function()
    sunfish.move_2_cell(91)
end)

bench("cell_2_move", N(1000000), function()
    sunfish.cell_2_move("a1")
end)

-- 3. Illegal move rejection (no genMoves traversal)
bench("move (illegal, e2e5)", N(200000), function()
    sunfish.move(game, "e2e5")
end)

-- 4. Full search via the public entry point. A single ai_move performs a
-- complete search (up to ~10k nodes) and is the heaviest public call.
-- Note: the engine's module-level transposition table persists across calls,
-- so repeated ai_move calls degrade; we benchmark one cold search.
-- Set SUNFISH_NO_YIELD=1 to disable the search coroutine's periodic yields
-- (uncapped throughput: no coroutine switches). The engine yields by default
-- for the Android RPD responsiveness loop; the benchmark measures the ceiling.
if os.getenv("SUNFISH_NO_YIELD") == "1" then
    sunfish.set_yield(nil, false)
end
bench("ai_move (full search, cold)", N(1), function()
    in_coroutine(function()
        local g = sunfish.new()
        sunfish.ai_move(g)
    end)
end)

print("\nBenchmarks complete.")
