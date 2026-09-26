-- tests/test_endgames.lua
-- Correctness tests for common endgames using the public API.
-- The expected behaviors were cross-validated against python-chess and
-- Stockfish (see tests/compare_python_chess.py).
-- Run: luajit tests/test_endgames.lua   (or lua / lua5.1)

local sunfish = require("sunfish")
local green = require("green")
local harness = require("tests.harness")
local describe, it = harness.describe, harness.it

-------------------------------------------------------------------------------
-- Board helpers: build a position from "square -> piece" placements.
-- Uppercase = side to move (engine convention).
-------------------------------------------------------------------------------

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
    -- Build the position in standard (white-frame) coordinates with standard
    -- case (white uppercase, black lowercase). If it is black to move, rotate
    -- the position so black's pieces are uppercase at the bottom (the engine's
    -- invariant) -- this matches how the engine itself rotates after each move.
    local g = sunfish.restore_data({ board = build_board(placements), score = 0,
        wc = { false, false }, bc = { false, false }, ep = 0, kp = 0 })
    if black_to_move then
        g = g:rotate()
    end
    return g
end

-- Run ai_move inside a coroutine (the engine yields during search).
local function ai_move(game)
    return green.run(function() return sunfish.ai_move(game) end)
end

-------------------------------------------------------------------------------
-- Mate / stalemate / check detection
-------------------------------------------------------------------------------

describe("endgame: checkmate detection", function()
    it("detects a back-rank mate", function()
        -- Black Kg8 (to move), white Rd8, black pawns f7 g7 h7.
        local g = newpos({ g8 = "k", d8 = "R", f7 = "p", g7 = "p", h7 = "p" }, true)
        assert_true(sunfish.in_check(g), "black king is in check")
        assert_true(sunfish.is_checkmate(g), "black has no escape")
        assert_false(sunfish.is_stalemate(g))
    end)

    it("detects a corner mate", function()
        -- Black Kh8 (to move), white Qg7 + white Kh6. Qg7# covers g8/h7.
        local g = newpos({ h8 = "k", g7 = "Q", h6 = "K" }, true)
        assert_true(sunfish.in_check(g), "black king in check")
        assert_true(sunfish.is_checkmate(g), "Kh8 Qg7 Kh6 is mate")
        assert_false(sunfish.is_stalemate(g))
    end)

    it("distinguishes check from mate", function()
        -- Black Ke8 (to move), white Re1+. Just check; black has escapes.
        local g = newpos({ e8 = "k", e1 = "R", g1 = "K" }, true)
        assert_true(sunfish.in_check(g))
        assert_false(sunfish.is_checkmate(g))
        assert_false(sunfish.is_stalemate(g))
        assert_equal(#sunfish.legal_moves(g), 4) -- e8d8 e8f8 e8d7 e8f7
    end)
end)

describe("endgame: stalemate detection", function()
    it("detects a classic stalemate", function()
        -- Black Ka8 (to move), white Qc7 + Kc6.
        local g = newpos({ a8 = "k", c7 = "Q", c6 = "K" }, true)
        assert_false(sunfish.in_check(g))
        assert_false(sunfish.is_checkmate(g))
        assert_true(sunfish.is_stalemate(g))
    end)

    it("detects the Qb6/Ka8 stalemate", function()
        -- Black Ka8 (to move), white Qb6 + Ka1.
        local g = newpos({ a8 = "k", b6 = "Q", a1 = "K" }, true)
        assert_true(sunfish.is_stalemate(g))
        assert_false(sunfish.is_checkmate(g))
    end)

    it("detects the Kc5 Qc7 stalemate", function()
        -- Black Ka8 (to move), white Qc7 + Kc5.
        local g = newpos({ a8 = "k", c7 = "Q", c5 = "K" }, true)
        assert_true(sunfish.is_stalemate(g))
        assert_false(sunfish.is_checkmate(g))
    end)
end)

-------------------------------------------------------------------------------
-- Legal move generation in endgames (validated vs python-chess)
-------------------------------------------------------------------------------

describe("endgame: legal move counts", function()
    it("KQK: Ke2 Qg7 vs Kh8 gives 30 legal moves", function()
        -- python-chess gives 31 including the king capture; standard chess = 30.
        local g = newpos({ e2 = "K", g7 = "Q", h8 = "k" })
        assert_equal(#sunfish.legal_moves(g), 30)
    end)

    it("KRK: Ke2 Rd1 vs Ke8 gives the python-chess move set size", function()
        -- Verified against python-chess FEN 4k3/8/8/8/8/8/4K3/3R4 w.
        local g = newpos({ e2 = "K", d1 = "R", e8 = "k" })
        assert_equal(#sunfish.legal_moves(g), 21)
    end)

    it("KPK: e7 pawn allows promotion and king moves", function()
        -- python-chess gives 9: 4 promotion moves (N/B/R/Q) + 5 king moves.
        local g = newpos({ e1 = "K", e7 = "P", h8 = "k" })
        assert_equal(#sunfish.legal_moves(g), 9)
    end)

    it("starting position has 20 legal moves", function()
        assert_equal(#sunfish.legal_moves(sunfish.new()), 20)
    end)

    it("rejects illegal endgame moves", function()
        local g = newpos({ e2 = "K", g7 = "Q", h8 = "k" })
        assert_false(sunfish.move(g, "e2e4"), "king cannot jump two squares")
        assert_false(sunfish.move(g, "e2h8"), "king cannot reach h8")
        assert_false(sunfish.move(g, "h8g7"), "cannot move the enemy king")
    end)
end)

-------------------------------------------------------------------------------
-- The engine plays winning endgames correctly
-------------------------------------------------------------------------------

describe("endgame: mate-in-1 delivery", function()
    -- With the bkm_light fast path (default on), KRK/KQK positions answer
    -- through the mover with score 0; the search path carries the mate-band
    -- score. Both paths are covered: mate DELIVERY here, mate SCORING in the
    -- distance-to-mate describe (fast path disabled there).
    it("KQK: delivers mate in one move", function()
        -- White (to move) Kf6 Qg7, black Kh8. Kf6g6 or Kf6f7 mates.
        local g = newpos({ f6 = "K", g7 = "Q", h8 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_table(ng)
        assert_true(type(mv) == "string" and #mv == 4, "must return a move")
        assert_true(sunfish.is_checkmate(ng), "resulting position must be checkmate")
        if sc ~= 0 then
            -- search path ran: the score must sit in the mate band
            assert_true(math.abs(sc) > sunfish.MATE_VALUE - 256, "score must indicate mate, got " .. tostring(sc))
        end
    end)

    it("KRK: delivers mate in one move", function()
        -- White (to move) Kg3 Ra1, black Kh1. Ra1b1# etc are mate.
        local g = newpos({ g3 = "K", a1 = "R", h1 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_table(ng)
        assert_true(type(mv) == "string" and #mv == 4, "must return a move")
        assert_true(sunfish.is_checkmate(ng), "resulting position must be checkmate")
        if sc ~= 0 then
            assert_true(math.abs(sc) > sunfish.MATE_VALUE - 256, "score must indicate mate, got " .. tostring(sc))
        end
    end)
end)

describe("endgame: stalemate avoidance", function()
    it("KQK: avoids the stalemate trap and finds the mate", function()
        -- White Kc6 Qd7, black Ka8, white to move. Qd7c7 stalemates; Qb7 mates.
        local g = newpos({ c6 = "K", d7 = "Q", a8 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_table(ng)
        assert_true(sunfish.is_checkmate(ng), "must deliver mate, not stalemate")
        assert_false(sunfish.is_stalemate(ng))
    end)
end)

describe("endgame: pawn promotion", function()
    it("promotes on reaching the last rank", function()
        -- White Pe7 pushes to e8 and promotes to a queen. The engine rotates
        -- the board after the move, so the promoted queen (now an enemy piece
        -- from black's view) appears at frame-d1 as lowercase q.
        local g = newpos({ e1 = "K", e7 = "P", h8 = "k" })
        local ng = sunfish.move(g, "e7e8")
        assert_true(ng ~= false, "e7e8 must be legal")
        local idx = sunfish.cell_2_move("d1") -- rotated frame position of e8
        assert_equal(ng.board:sub(idx + 1, idx + 1), "q", "promoted queen at frame-d1")
    end)
end)

describe("endgame: distance-to-mate scoring", function()
    -- Search-path scores: the fast path is disabled for this describe (it
    -- answers KRK/KQK instantly with score 0). The mini-harness has no
    -- before_each, so each test sets and restores the flag explicitly.
    it("scores a mate in 1 at MATE_VALUE - 1", function()
        -- KQK: Kf6 Qg7 vs Kh8, white to move, mate in one.
        local prev = sunfish.set_use_bkm_light(false)
        local g = newpos({ f6 = "K", g7 = "Q", h8 = "k" })
        local ng, mv, sc = ai_move(g)
        sunfish.set_use_bkm_light(prev)
        assert_equal(sc, sunfish.MATE_VALUE - 1, "mate-in-1 must score MATE_VALUE - 1")
        assert_true(sunfish.is_checkmate(ng))
    end)

    it("scores a KRK mate in 1 at MATE_VALUE - 1", function()
        -- KRK: Kg6 Rd7 vs Kh8, white to move, mate in one.
        local prev = sunfish.set_use_bkm_light(false)
        local g = newpos({ g6 = "K", d7 = "R", h8 = "k" })
        local ng, mv, sc = ai_move(g)
        sunfish.set_use_bkm_light(prev)
        assert_equal(sc, sunfish.MATE_VALUE - 1, "KRK mate-in-1 must score MATE_VALUE - 1, got " .. tostring(sc))
        assert_true(sunfish.is_checkmate(ng))
    end)

    it("gives the search a gradient: a near-mate scores higher than a distant one", function()
        -- The king-corraling endgame eval must produce a nonzero score even
        -- when the mate is not immediately visible at the search horizon.
        local prev = sunfish.set_use_bkm_light(false)
        local g = newpos({ e1 = "K", d3 = "Q", h8 = "k" })
        local ng, mv, sc = ai_move(g)
        sunfish.set_use_bkm_light(prev)
        assert_true(sc > 0, "a winning KQK must have a positive gradient, got " .. tostring(sc))
    end)
end)

describe("endgame: draw rules", function()
    it("K vs K is a draw", function()
        local g = newpos({ e1 = "K", e8 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_equal(sc, 0, "K vs K must score 0")
    end)

    it("K+B vs K is a draw", function()
        local g = newpos({ e1 = "K", c4 = "B", e8 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_equal(sc, 0, "K+B vs K must score 0")
    end)

    it("K+N vs K is a draw", function()
        local g = newpos({ e1 = "K", c4 = "N", e8 = "k" })
        local ng, mv, sc = ai_move(g)
        assert_equal(sc, 0, "K+N vs K must score 0")
    end)

    it("the 50-move rule fires at fifty >= 100", function()
        -- K+R vs K is a win, but with the clock at 99 half-moves the search
        -- must see the immediate 50-move draw and not claim a win.
        local g = newpos({ e1 = "K", d2 = "R", e8 = "k" })
        g.fifty = 99
        local ng, mv, sc = ai_move(g)
        assert_equal(sc, 0, "fifty=99 must draw, got " .. tostring(sc))
    end)
end)

harness.finish()
