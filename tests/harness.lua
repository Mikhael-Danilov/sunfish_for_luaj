-- tests/harness.lua
-- Minimal zero-dependency test harness compatible with Lua 5.1+ and LuaJIT.
-- Provides describe()/it()/assert* helpers and a colored TAP-like summary.

local harness = {}
local results = { pass = 0, fail = 0, skip = 0 }
local failures = {}
local current_suite = "?"
local suite_started = false

local function color(code, text)
    if os.getenv("NO_COLOR") then return text end
    local ok, isatty = pcall(function()
        if io.stdout.isatty then return io.stdout:isatty() end
        return false
    end)
    if ok and isatty then
        return "\27[" .. code .. "m" .. text .. "\27[0m"
    end
    return text
end

-- The engine's search loop calls coroutine.yield() every 30 nodes (it is
-- designed to be driven from a coroutine, like the original sunfish). pcall
-- cannot yield across the C boundary, so test bodies are run inside a fresh
-- coroutine instead. Errors are propagated back as normal exceptions.
local function coroutine_guard(fn)
    local co = coroutine.create(fn)
    local deadline = os.clock() + tonumber(os.getenv("TEST_BUDGET") or 30) -- 30s of engine search per test
    local ok, err = coroutine.resume(co)
    -- Keep resuming while the engine yields; stop after the time budget.
    while ok and coroutine.status(co) == "suspended" and os.clock() < deadline do
        ok, err = coroutine.resume(co)
    end
    if ok and coroutine.status(co) == "suspended" then
        -- Budget exhausted mid-search: report instead of hanging forever.
        return false, "test exceeded the engine-search budget (TEST_BUDGET=" .. tostring(os.getenv("TEST_BUDGET") or 30) .. "s)"
    end
    return ok, err
end

local function suite(name, fn)
    current_suite = name
    suite_started = false
    local ok, err = coroutine_guard(fn)
    if not ok then
        -- The whole suite body threw outside of an it(); record as a failure.
        results.fail = results.fail + 1
        table.insert(failures, string.format("%s: suite error: %s", name, err))
    end
    current_suite = "?"
end

local function it(name, fn)
    if not suite_started then
        print("\n" .. current_suite)
        suite_started = true
    end
    local ok, err = coroutine_guard(fn)
    if ok then
        results.pass = results.pass + 1
        print(color("32", "  \u{2713}") .. " " .. name)
    else
        results.fail = results.fail + 1
        local msg = tostring(err):gsub("\n", "\n      ")
        table.insert(failures, string.format("%s: %s\n      %s", current_suite, name, msg))
        print(color("31", "  \u{2717}") .. " " .. name .. color("31", "  FAILED"))
        print("      " .. msg)
    end
end

local function it_skip(name)
    results.skip = results.skip + 1
    print(color("33", "  -") .. " " .. name .. " (skipped)")
end

-- Assertions (each returns a truthy value so they can be chained with `and`).

local function assert_equal(actual, expected, context)
    if actual ~= expected then
        error(string.format(
            "expected %s, got %s%s",
            tostring(expected), tostring(actual),
            context and (" (" .. context .. ")") or ""), 2)
    end
    return true
end

local function assert_not_equal(actual, unexpected, context)
    if actual == unexpected then
        error(string.format(
            "did not expect %s%s",
            tostring(actual),
            context and (" (" .. context .. ")") or ""), 2)
    end
    return true
end

local function assert_true(value, context)
    if not value then
        error("expected truthy value" .. (context and (" (" .. context .. ")") or ""), 2)
    end
    return true
end

local function assert_false(value, context)
    if value then
        error("expected falsy value, got " .. tostring(value) .. (context and (" (" .. context .. ")") or ""), 2)
    end
    return true
end

local function assert_nil(value, context)
    if value ~= nil then
        error("expected nil, got " .. tostring(value) .. (context and (" (" .. context .. ")") or ""), 2)
    end
    return true
end

local function assert_table(value, context)
    if type(value) ~= "table" then
        error("expected table, got " .. type(value) .. (context and (" (" .. context .. ")") or ""), 2)
    end
    return true
end

-- Runs a function and asserts it raises no error.
local function assert_no_throw(fn, context)
    local ok, err = pcall(fn)
    if not ok then
        error("unexpected error: " .. tostring(err) .. (context and (" (" .. context .. ")") or ""), 2)
    end
    return true
end

-- Runs a function and asserts it raises an error.
local function assert_throws(fn, context)
    local ok, err = pcall(fn)
    if ok then
        error("expected an error to be raised" .. (context and (" (" .. context .. ")") or ""), 2)
    end
    return true
end

local function finish()
    print("\n" .. string.rep("-", 60))
    print(string.format("passed: %d  failed: %d  skipped: %d", results.pass, results.fail, results.skip))
    if results.fail > 0 then
        print("\nFailures:")
        for _, f in ipairs(failures) do
            print("  " .. f)
        end
        os.exit(1)
    else
        os.exit(0)
    end
end

harness.describe = suite
harness.it = it
harness.it_skip = it_skip
harness.finish = finish

-- Expose assertions as plain globals for convenience inside test files.
-- NOTE: require wraps this file in a function, so bare assignments would create
-- locals; write to _G explicitly to make them true globals.
assert_equal = assert_equal
_G.assert_equal = assert_equal
assert_not_equal = assert_not_equal
_G.assert_not_equal = assert_not_equal
assert_true = assert_true
_G.assert_true = assert_true
assert_false = assert_false
_G.assert_false = assert_false
assert_nil = assert_nil
_G.assert_nil = assert_nil
assert_table = assert_table
_G.assert_table = assert_table
assert_no_throw = assert_no_throw
_G.assert_no_throw = assert_no_throw
assert_throws = assert_throws
_G.assert_throws = assert_throws

return harness
