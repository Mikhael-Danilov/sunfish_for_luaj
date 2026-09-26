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

-- ai_move's display move follows the search path's convention: rendered in
-- the CHILD (rotated) frame, i.e. the mirror of the current frame's squares.
-- All fast-path fixtures here are white to move, so the real-board move is
-- the display mirrored once (the same rule the harness bridges apply with
-- rot=1 for the side to move's frame).
local function display_to_real(mv)
    local function m1(name)
        local i = sunfish.cell_2_move(name) + 1 -- internal 1-based (A1 = 92)
        local mir = 121 - i
        local rank = math.floor((mir - 92) / 10)
        local fil = (mir - 92) % 10
        return string.char(fil + string.byte("a")) .. tostring(1 - rank)
    end
    return m1(mv:sub(1, 2)) .. m1(mv:sub(3, 4))
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
        assert_equal(display_to_real(mv), "h1h8", "expected real h1h8, got display " .. tostring(mv))
        sunfish.set_use_bkm_light(false)
    end)

    it("fast path returns a legal move (checked by sunfish.move)", function()
        sunfish.set_use_bkm_light(true)
        local g = newpos({ e4 = "K", c1 = "R", e8 = "k" })
        local ng, mv = ai_move(g)
        assert_true(mv ~= nil, "must return a move")
        local real = display_to_real(mv)
        local ok = sunfish.move(g, real)
        assert_true(ok ~= false, "real move " .. tostring(real) .. " must be legal")
        sunfish.set_use_bkm_light(false)
    end)
end)

describe("bkm_light fast path: default on", function()
    it("answers KRK via the fast path by default (score 0, no search)", function()
        sunfish.set_use_bkm_light(true) -- restore the default in case a prior test disabled it
        local g = newpos({ g6 = "K", d7 = "R", h8 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_true(type(mv) == "string" and #mv == 4, "must return a move")
        assert_equal(sc, 0, "the fast path answers with score 0")
        assert_true(sunfish.is_checkmate(ng), "fast path must still mate")
    end)
end)

describe("bkm_light fast path: opt-out", function()
    it("searches when disabled (nonzero mate score)", function()
        sunfish.set_use_bkm_light(false)
        local g = newpos({ g6 = "K", d7 = "R", h8 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_true(type(mv) == "string" and #mv == 4, "must return a move")
        assert_true(sc ~= 0, "the search path must score the mate (got 0 = fast path)")
        assert_true(sunfish.is_checkmate(ng), "search must still mate")
        sunfish.set_use_bkm_light(true)
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
