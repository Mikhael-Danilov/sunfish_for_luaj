-- tests/test_bkm_light_integration.lua
-- Integration tests for the bkm_light KRK/KQK fast path in sunfish.
-- When sunfish.set_use_bkm_light(true), ai_move must answer K+R vs K and
-- K+Q vs K positions instantly with legal moves that lead to mate (or correct
-- draws), and all other positions must still go through the normal search.
--
-- Run: luajit tests/test_bkm_light_integration.lua

local sunfish = require("sunfish")
local green = require("green")
local harness = require("tests.harness")
local describe, it = harness.describe, harness.it

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
    return table.concat(out)
end

local function newpos(placements, black_to_move)
    local g = sunfish.restore_data({ board = build_board(placements), score = 0,
        wc = { false, false }, bc = { false, false }, ep = 0, kp = 0 })
    if black_to_move then
        g = g:rotate()
    end
    return g
end

-- ai_move inside a coroutine (the engine yields during search).
local function ai_move(game)
    return green.run(function() return sunfish.ai_move(game) end)
end

describe("bkm_light fast path: KRK/KQK mate delivery", function()
    it("KRK: delivers mate in one via the fast path", function()
        sunfish.set_use_bkm_light(true)
        local g = newpos({ g6 = "K", d7 = "R", h8 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_true(type(mv) == "string" and #mv == 4, "must return a move, got " .. tostring(mv))
        assert_true(sunfish.is_checkmate(ng), "resulting position must be checkmate, got " .. tostring(mv))
        sunfish.set_use_bkm_light(false)
    end)

    it("KQK: delivers mate in one via the fast path", function()
        sunfish.set_use_bkm_light(true)
        local g = newpos({ f6 = "K", g7 = "Q", h8 = "k" })
        local ng, mv = ai_move(g)
        assert_true(type(mv) == "string" and #mv == 4, "must return a move, got " .. tostring(mv))
        assert_true(sunfish.is_checkmate(ng), "resulting position must be checkmate, got " .. tostring(mv))
        sunfish.set_use_bkm_light(false)
    end)

    it("KQK: avoids the stalemate trap via the fast path", function()
        sunfish.set_use_bkm_light(true)
        local g = newpos({ c6 = "K", d7 = "Q", a8 = "k" })
        local ng, mv = ai_move(g)
        assert_true(type(mv) == "string" and #mv == 4, "must return a move, got " .. tostring(mv))
        assert_true(sunfish.is_checkmate(ng), "must deliver mate, not stalemate, got " .. tostring(mv))
        assert_false(sunfish.is_stalemate(ng))
        sunfish.set_use_bkm_light(false)
    end)

    it("KRK: matches the documented h1h8 example", function()
        sunfish.set_use_bkm_light(true)
        local g = newpos({ b6 = "K", h1 = "R", a8 = "k" })
        local _, mv = ai_move(g)
        assert_equal(mv, "h1h8", "expected h1h8, got " .. tostring(mv))
        sunfish.set_use_bkm_light(false)
    end)

    it("fast path returns a legal move (checked by sunfish.move)", function()
        sunfish.set_use_bkm_light(true)
        local g = newpos({ e4 = "K", c1 = "R", e8 = "k" })
        local ng, mv = ai_move(g)
        assert_true(mv ~= nil, "must return a move")
        local ok = sunfish.move(g, mv)
        assert_true(ok ~= false, "move " .. tostring(mv) .. " must be legal")
        sunfish.set_use_bkm_light(false)
    end)
end)

describe("bkm_light fast path: default off", function()
    it("does not change behavior when disabled (still searches)", function()
        sunfish.set_use_bkm_light(false)
        local g = newpos({ g6 = "K", d7 = "R", h8 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_true(type(mv) == "string" and #mv == 4, "must return a move")
        assert_true(sunfish.is_checkmate(ng), "search must still mate")
    end)
end)

describe("bkm_light fast path: only fires for KRK/KQK", function()
    it("K+B vs K stays on the search path (draw)", function()
        sunfish.set_use_bkm_light(true)
        local g = newpos({ e1 = "K", c4 = "B", e8 = "k" })
        local ng, mv, sc = ai_move(g)
        -- K+B vs K is a draw; the search returns no move with score 0. The
        -- fast path must not interfere (it only fires for K+R/K+Q vs K).
        assert_equal(sc, 0, "K+B vs K must score 0, got " .. tostring(sc))
        sunfish.set_use_bkm_light(false)
    end)
end)

harness.finish()
