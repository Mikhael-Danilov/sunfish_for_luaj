-- benchmarks/bench_bkm_light_luaj.lua
-- Benchmark the bkm_light KRK/KQK fast path vs the full search under LuaJ
-- (the Java-based Lua interpreter, deployment target). Run via
-- benchmarks/run_luaj.sh (BENCH_SCALE shrinks iterations for the slow VM):
--
--   BENCH_SCALE=0.01 benchmarks/run_luaj.sh benchmarks/bench_bkm_light_luaj.lua
--
-- Measures, for K+R vs K / K+Q vs K:
--   * full-search ai_move wall time (fast path disabled)
--   * fast-path ai_move wall time (bkm_light enabled)
--   * memory footprint of requiring bkm_light

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
        "  %-42s %8d iters  %10.2f ms  %10.1f iter/s  (%6.3f ms/iter)",
        name, iters, dt, dt > 0 and (iters / dt * 1000) or math.huge,
        dt / iters))
    return dt
end

-- The engine's search yields periodically; run ai_move inside a coroutine.
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

local scale = tonumber(os.getenv("BENCH_SCALE")) or 1
if scale <= 0 or scale > 1 then scale = 1 end
local function N(n)
    return math.max(1, math.floor(n * scale))
end

-- Build a position from "square -> piece" placements (uppercase = to move).
local function build_board(placements)
    local rows = {}
    rows[0] = "         \n"
    rows[1] = "         \n"
    rows[10] = "         \n"
    rows[11] = "          "
    for r = 2, 9 do
        local row = { " " }
        for c = 1, 8 do row[c + 1] = "." end
        row[10] = "\n"
        rows[r] = table.concat(row)
    end
    for cell, piece in pairs(placements) do
        local f, r = cell:sub(1, 1), tonumber(cell:sub(2, 2))
        local i = (10 - r) * 10 + (f:byte() - string.byte("a") + 1)
        local row = math.floor(i / 10)
        local col = i % 10
        rows[row] = rows[row]:sub(1, col) .. piece .. rows[row]:sub(col + 2)
    end
    local out = {}
    for r = 0, 11 do out[r + 1] = rows[r] end
    return sunfish.restore_data({ board = table.concat(out), score = 0,
        wc = { false, false }, bc = { false, false }, ep = 0, kp = 0 })
end

print(string.format("Lua: %s", _VERSION))
print()

-- One representative KRK and one KQK position, several plies from mate.
local KRK = build_board({ e4 = "K", c1 = "R", e8 = "k" })
local KQK = build_board({ c6 = "K", d7 = "Q", a8 = "k" })

if os.getenv("SUNFISH_NO_YIELD") == "1" then
    sunfish.set_yield(nil, false)
end

-- Sanity: both paths return a legal move on these positions.
sunfish.set_use_bkm_light(false)
in_coroutine(function()
    local _, mv = sunfish.ai_move(build_board({ e4 = "K", c1 = "R", e8 = "k" }))
    assert(mv, "search must return a KRK move")
end)
in_coroutine(function()
    local _, mv = sunfish.ai_move(build_board({ c6 = "K", d7 = "Q", a8 = "k" }))
    assert(mv, "search must return a KQK move")
end)
sunfish.set_use_bkm_light(true)
local _, mv1 = (function()
    return green.run(function() return sunfish.ai_move(build_board({ e4 = "K", c1 = "R", e8 = "k" })) end)
end)()
assert(mv1, "fast path must return a KRK move")
sunfish.set_use_bkm_light(false)

print("fast path and search both return moves; benchmarking...")
print()

-- Warm up each path once (LuaJ cold-start on the first call is not
-- representative; the engine's module tables also warm up).
sunfish.set_use_bkm_light(true)
in_coroutine(function()
    sunfish.ai_move(build_board({ e4 = "K", c1 = "R", e8 = "k" }))
end)
in_coroutine(function()
    sunfish.ai_move(build_board({ c6 = "K", d7 = "Q", a8 = "k" }))
end)
sunfish.set_use_bkm_light(false)
in_coroutine(function()
    sunfish.ai_move(build_board({ e4 = "K", c1 = "R", e8 = "k" }))
end)

-- Throughput (fresh position per call to avoid TT/pool aliasing effects).
local n = N(20)
sunfish.set_use_bkm_light(false)
bench("KRK full search ai_move", n, function()
    in_coroutine(function()
        sunfish.ai_move(build_board({ e4 = "K", c1 = "R", e8 = "k" }))
    end)
end)

sunfish.set_use_bkm_light(true)
bench("KRK bkm_light fast path ai_move", n, function()
    in_coroutine(function()
        sunfish.ai_move(build_board({ e4 = "K", c1 = "R", e8 = "k" }))
    end)
end)

sunfish.set_use_bkm_light(false)
bench("KQK full search ai_move", n, function()
    in_coroutine(function()
        sunfish.ai_move(build_board({ c6 = "K", d7 = "Q", a8 = "k" }))
    end)
end)

sunfish.set_use_bkm_light(true)
bench("KQK bkm_light fast path ai_move", n, function()
    in_coroutine(function()
        sunfish.ai_move(build_board({ c6 = "K", d7 = "Q", a8 = "k" }))
    end)
end)
