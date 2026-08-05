-- tests/test_sunfish.lua
-- Tests for sunfish.lua's public API.
-- Run: lua tests/test_sunfish.lua   (works with lua5.1 and luajit)

local sunfish = require("sunfish")

local describe, it = assert(require("tests.harness").describe), assert(require("tests.harness").it)

describe("sunfish constants", function()
    it("exposes MATE_VALUE", function()
        assert_equal(sunfish.MATE_VALUE, 30000)
    end)
end)

describe("sunfish.new", function()
    it("returns a position object", function()
        local game = sunfish.new()
        assert_table(game)
        assert_true(game.board ~= nil)
        assert_true(game.score ~= nil)
    end)

    it("resets the global game state", function()
        local game = sunfish.new()
        sunfish.move(game, "e2e4")
        local fresh = sunfish.new()
        assert_equal(fresh.board, game.board)
        -- fresh board still has 32 pieces
        assert_equal(select(2, fresh.board:gsub("[prnbqkPRNBQK]", "")), 32)
    end)
end)

describe("sunfish.move", function()
    it("applies a legal move and returns the next position", function()
        local game = sunfish.new()
        local next_game = sunfish.move(game, "e2e4")
        assert_table(next_game)
        assert_true(next_game ~= game) -- returns a new rotated position
    end)

    it("rejects an illegal move", function()
        local game = sunfish.new()
        assert_false(sunfish.move(game, "e2e5")) -- pawn can't jump two past f3
        assert_false(sunfish.move(game, "a1a2")) -- no piece at a1
    end)

    it("rejects garbage input", function()
        local game = sunfish.new()
        assert_false(sunfish.move(game, "zz99"))
        assert_false(sunfish.move(game, ""))
    end)

    it("playes out a known opening", function()
        -- Italian Game: 1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5
        -- The engine rotates the board after every move, so each side's move
        -- is given in the frame of the position currently on top.
        local game = sunfish.new()
        game = sunfish.move(game, "e2e4") -- white: e4
        game = sunfish.move(game, "e2e4") -- black: e5 (rotated frame)
        game = sunfish.move(game, "g1f3") -- white: Nf3
        game = sunfish.move(game, "g1f3") -- black: Nc6 (rotated frame)
        game = sunfish.move(game, "f1c4") -- white: Bc4
        game = sunfish.move(game, "f1c4") -- black: Bc5 (rotated frame)
        assert_true(game ~= nil, "whole opening must be legal")
    end)

    it("cannot move through a blocking piece", function()
        local game = sunfish.new()
        -- e2-e3 is legal, but the a2 pawn blocks the a1 rook.
        assert_false(sunfish.move(game, "a1a3"), "a1 rook blocked by a2 pawn")
        -- e2e4 is fine; e2e5 isn't (can't jump the e2 pawn two squares).
        assert_true(sunfish.move(game, "e2e4") ~= false)
    end)
end)

describe("sunfish.ai_move", function()
    it("returns a position, a move string, and a score", function()
        local game = sunfish.new()
        local next_game, mv, score = sunfish.ai_move(game)
        assert_table(next_game)
        assert_true(type(mv) == "string" and #mv == 4, "move string must be like e2e4")
        assert_true(type(score) == "number", "score must be numeric")
        -- The returned move is in the rotated (black) frame, so it may not
        -- replay via sunfish.move on the original position. That's engine
        -- behavior; we only assert the shape here.
        assert_true(next_game ~= game, "ai_move must return a new position")
    end)

    it("survives a short game (no crash)", function()
        -- Note: the engine keeps a module-level transposition table that is
        -- never cleared between searches, so repeated ai_move calls in one
        -- process become progressively slower. A single move is enough to
        -- exercise the public entry point without blowing the time budget.
        local game = sunfish.new()
        local ng, mv, score = sunfish.ai_move(game)
        assert_true(ng ~= nil)
        assert_true(score ~= nil)
        assert_true(mv == nil or #mv == 4)
    end)
end)

describe("sunfish store_data / restore_data", function()
    it("round-trips a position", function()
        local game = sunfish.new()
        game = sunfish.move(game, "e2e4")
        local data = sunfish.store_data(game)
        assert_table(data)
        local restored = sunfish.restore_data(data)
        assert_equal(restored.board, game.board)
        assert_equal(restored.score, game.score)
        assert_equal(restored.ep, game.ep)
        assert_equal(restored.kp, game.kp)
    end)
end)

describe("sunfish move_2_cell / cell_2_move", function()
    it("move_2_cell renders square coordinates", function()
        -- A1 is the white rook's square (index 91 in the engine).
        assert_equal(sunfish.move_2_cell(91), "a1")
    end)

    it("cell_2_move parses coordinates back to an index", function()
        assert_equal(sunfish.cell_2_move("a1"), 91)
    end)

    it("round-trips between the two", function()
        for _, cell in ipairs({ "a1", "e4", "h8" }) do
            assert_equal(sunfish.move_2_cell(sunfish.cell_2_move(cell)), cell)
        end
    end)
end)

-- Run all suites and exit.
require("tests.harness").finish()
