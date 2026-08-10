-- benchmarks/verify_invariant.lua
-- Node-count + move/score invariant verifier for the current baseline.
--
-- Runs one cold start-position search and asserts the invariant the plan uses
-- as the guard rail for behavior-identical changes:
--   nodes 27/153/287/1007, root move d7d5 (1000-node default budget).
-- The engine's search prints "Searched %d nodes. Depth %d. Score %d(...)" per
-- depth; we capture that and check it against the expected sequence.
--
-- Usage: SUNFISH_VERBOSE=1 luajit benchmarks/verify_invariant.lua   (or via run_luaj.sh)
-- Exit 0 if the invariant holds, 1 otherwise (with a diff of what changed).

-- The per-depth search progress print is gated behind SUNFISH_VERBOSE=1
-- (the engine runs silent by default); the verifier needs it to capture the
-- depth-by-depth node counts. Run with SUNFISH_VERBOSE=1 (see the header).
local sunfish = require("sunfish")

-- Current baseline (post promotion-expansion + auto-queen-removal bug fixes,
-- default NODES_SEARCHED = 1000, plus endgame draw rules): the budget-aware
-- stop cuts the search off mid-depth 4 at 1008 nodes, so only depths 1-4 are
-- reached. Node counts legitimately changed (budget default, the auto-queen
-- fix, and the 50-move/repetition/insufficient-material draw checks that now
-- return draw scores before the TT probe), so this is the invariant every
-- behavior-identical batch must preserve.
local EXPECTED = {
    { depth = 1, nodes = 27,   score = 99 },
    { depth = 2, nodes = 153,  score = 0 },
    { depth = 3, nodes = 287,  score = 99 },
    { depth = 4, nodes = 1008, score = 40 },
}
-- The invariant root move (current baseline): d7d5.
local EXPECTED_MOVE = "d7d5"

local captured = {}
local orig_print = print
local function capture(...)
    -- The engine prints: "Searched %d nodes. Depth %d. Score %d(%d/%d)"
    -- The window bounds can be negative (F3 aspiration re-search), so allow
    -- an optional leading minus. capture depth (cap1) and score (cap2);
    -- nodes is the first field.
    local s = tostring(select(1, ...))
    local d, sc = s:match("Depth (%d+)%. Score (%d+)%((-?%d+)/(%-?%d+)")
    local nodes = s:match("Searched (%d+) nodes")
    if d and nodes then
        captured[tonumber(d)] = { depth = tonumber(d), nodes = tonumber(nodes), score = tonumber(sc) }
    end
    orig_print(s)
end
print = capture

-- Drive ai_move from a coroutine (the engine yields during search).
local co = coroutine.create(function()
    local g = sunfish.new()
    local _, mv, sc = sunfish.ai_move(g)
    return mv, sc
end)
local ok, mv, sc = coroutine.resume(co)
while ok and coroutine.status(co) == "suspended" do
    ok, mv, sc = coroutine.resume(co)
end
if not ok then error(mv, 0) end

print = orig_print

local failures = 0
for _, exp in ipairs(EXPECTED) do
    local got = captured[exp.depth]
    if not got then
        print(("MISSING depth %d (expected %d nodes, score %d)"):format(exp.depth, exp.nodes, exp.score))
        failures = failures + 1
    elseif got.nodes ~= exp.nodes or got.score ~= exp.score then
        print(("DIFF depth %d: expected %d nodes/sc %d, got %d nodes/sc %d"):format(
            exp.depth, exp.nodes, exp.score, got.nodes, got.score))
        failures = failures + 1
    else
        print(("ok depth %d: %d nodes, score %d"):format(exp.depth, exp.nodes, exp.score))
    end
end

-- The exact root move must be the known invariant (d7d5 in the rotated
-- frame, matching the current baseline's ai_move output).
if mv == EXPECTED_MOVE then
    print(("root move: %s (invariant)"):format(mv))
else
    print(("root move: %s (expected %s)"):format(tostring(mv), EXPECTED_MOVE))
    failures = failures + 1
end

if failures == 0 then
    print("INVARIANT OK")
    os.exit(0)
else
    print("INVARIANT BROKEN")
    os.exit(1)
end
