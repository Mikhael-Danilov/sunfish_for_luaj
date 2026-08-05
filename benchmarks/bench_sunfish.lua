-- benchmarks/bench_sunfish.lua
-- Benchmarks for sunfish.lua's public API.
-- Run: luajit benchmarks/bench_sunfish.lua   (or lua / lua5.1)

local sunfish = require("sunfish")

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
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    while ok and coroutine.status(co) == "suspended" do
        ok, err = coroutine.resume(co)
    end
    if not ok then
        error(err)
    end
end

print(string.format("Lua: %s", _VERSION))
print(string.format("sunfish.MATE_VALUE = %d\n", sunfish.MATE_VALUE))

local game = sunfish.new()

-- 1. Position lifecycle
bench("sunfish.new", 100000, function()
    sunfish.new()
end)

bench("sunfish.move (e2e4)", 20000, function()
    sunfish.move(game, "e2e4")
end)

bench("store_data / restore_data round-trip", 50000, function()
    local d = sunfish.store_data(game)
    sunfish.restore_data(d)
end)

-- 2. Coordinate conversion
bench("move_2_cell", 1000000, function()
    sunfish.move_2_cell(91)
end)

bench("cell_2_move", 1000000, function()
    sunfish.cell_2_move("a1")
end)

-- 3. Illegal move rejection (no genMoves traversal)
bench("move (illegal, e2e5)", 200000, function()
    sunfish.move(game, "e2e5")
end)

-- 4. Full search via the public entry point. A single ai_move performs a
-- complete search (up to ~10k nodes) and is the heaviest public call.
-- Note: the engine's module-level transposition table persists across calls,
-- so repeated ai_move calls degrade; we benchmark one cold search.
bench("ai_move (full search, cold)", 1, function()
    in_coroutine(function()
        local g = sunfish.new()
        sunfish.ai_move(g)
    end)
end)

print("\nBenchmarks complete.")
