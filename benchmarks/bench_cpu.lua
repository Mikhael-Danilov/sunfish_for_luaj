-- benchmarks/bench_cpu.lua
-- CPU-time variant of bench_sunfish.lua's ai_move benchmark.
--
-- Run with the LuajCpuRun launcher (installs os.cpuclock() = ThreadMXBean
-- thread CPU ms). Times one cold ai_move search with TRUE CPU time, immune
-- to machine load. Also prints the OS-level wall and CPU elapsed from
-- /usr/bin/time if present (the caller greps the output).
--
-- Usage:
--   java -cp .reference:.reference/luaj-jse-3.0.2.jar \
--        -Dluaj.path="<engine_dir>/?.lua;<repo>/tests/?.lua" \
--        LuajCpuRun benchmarks/bench_cpu.lua [tag]

local sunfish = require("sunfish")

if os.getenv("SUNFISH_NO_YIELD") == "1" then
    sunfish.set_yield(nil, false)
end

local function in_coroutine(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    while ok and coroutine.status(co) == "suspended" do
        ok, err = coroutine.resume(co)
    end
    if not ok then error(err) end
end

local tag = arg and arg[1] or "run"
-- Warm-up is NOT used (cold JVM is the established protocol); cpuclock reads
-- only the calling thread's CPU time so startup/GC/other JVM threads are out.
local t0 = os.cpuclock()
in_coroutine(function()
    local g = sunfish.new()
    sunfish.ai_move(g)
end)
local dt = os.cpuclock() - t0

print(string.format("cpu ai_move (%s): %.1f ms", tag, dt))
