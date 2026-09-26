-- green.lua — drive a yielding function (the sunfish search) on whatever
-- green-thread facility the host Lua provides.
--
-- The engine yields via fiber.yield when our LuaJ fork's zero-thread fiber
-- library is installed (search must then be driven from fiber.create), else
-- via coroutine.yield (drive from coroutine.create). All tests and benchmarks
-- go through green.run so the same script runs unchanged on both.
--
--   green.kind()        -> "fiber" | "coroutine"
--   green.run(fn, ...)  -> fn's return values; errors propagate
local M = {}

local pack = table.pack or function(...)
    return { n = select("#", ...), ... }
end
local unpack = table.unpack or unpack

local F = coroutine
local has_fiber = type(fiber) == "table" and type(fiber.yield) == "function"
if has_fiber then
    F = fiber
else
    local ok, lib = pcall(require, "fiber")
    if ok and type(lib) == "table" and type(lib.yield) == "function" then
        F, has_fiber = lib, true
    end
end

function M.kind()
    return has_fiber and "fiber" or "coroutine"
end

function M.run(fn, ...)
    local co = F.create(fn)
    local n = select("#", ...)
    local args = { ... }
    local vals = pack(F.resume(co, unpack(args, 1, n)))
    while vals[1] and F.status(co) == "suspended" do
        vals = pack(F.resume(co))
    end
    if not vals[1] then
        error(vals[2], 2)
    end
    return unpack(vals, 2, vals.n)
end

-- Like run, but consults poll() before each subsequent resume; when poll
-- returns false the run aborts with (false, "TIMEOUT"). Used by the test
-- harness's TEST_BUDGET so a wedged search fails instead of hanging.
function M.guard(fn, poll, ...)
    local co = F.create(fn)
    local n = select("#", ...)
    local args = { ... }
    local vals = pack(F.resume(co, unpack(args, 1, n)))
    while vals[1] and F.status(co) == "suspended" do
        if poll and not poll() then
            return false, "TIMEOUT"
        end
        vals = pack(F.resume(co))
    end
    if not vals[1] then
        return false, vals[2]
    end
    return true
end

return M
