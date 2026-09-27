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
local green = require("green")

-- Current baseline (round 4, 2026-09-27: countermove ordering + qsearch delta
-- pruning + capture-only qsearch generation (SUNFISH_COQ) + the perf batch —
-- flat PST, parallel-bonus sort, sparse pooled boards), default
-- NODES_SEARCHED = 1000. Depths 1-3 are bit-identical to round 3 (the new
-- heuristics don't fire there); depth 4 converges 7 nodes cheaper and the
-- search now starts a depth-5 probe inside the same budget (the node
-- efficiency the round bought). This is the invariant every future
-- behavior-identical batch must preserve.
local EXPECTED = {
    { depth = 1, nodes = 23,   score = 99 },
    { depth = 2, nodes = 64,   score = 0 },
    { depth = 3, nodes = 109,  score = 99 },
    { depth = 4, nodes = 997,  score = 0 },
    { depth = 5, nodes = 1001, score = 99 },
}
-- The invariant root move (current baseline): b8c6.
-- 2026-09-26 (round 3): null-move probes now require depth >= 3 (shallow null
-- probes fed MTD phantom cutoffs — see the null-move block in sunfish.lua), so
-- depths 1-3 lost their null subtrees (27/153/287 -> 23/64/109). The root loop
-- is an MTD(f) zero-window walk (SUNFISH_MTDF=0 reverts to bisection), which
-- changes depth-4's converged score (20 -> 36 at 1004 nodes). Check extension,
-- qsearch check-evasion (QSE_FLOOR -4) and the endgame king-activity leaf term
-- don't fire at the 32-piece start position. This verifier remains the guard
-- rail for future behavior-identical batches against THIS baseline.
-- 2026-09-27 (round 4): depth 4 is 997/0 and a depth-5 probe starts (1001/99,
-- cut by the budget) — see EXPECTED above.
local EXPECTED_MOVE = "b8c6"

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

-- Drive ai_move from a green thread (the engine yields during search).
local mv, sc = green.run(function()
    local g = sunfish.new()
    local _, mv, sc = sunfish.ai_move(g)
    return mv, sc
end)

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
