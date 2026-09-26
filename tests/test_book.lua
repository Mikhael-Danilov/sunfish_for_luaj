-- tests/test_book.lua
-- Tests for sunfish.lua's opening book API (set_book + ai_move integration).
-- Run: luajit tests/test_book.lua   (works with lua5.1 and luajit)

local sunfish = require("sunfish")
local green = require("green")

local describe, it = assert(require("tests.harness").describe), assert(require("tests.harness").it)

local function ai_move(game)
    return green.run(function() return sunfish.ai_move(game) end)
end

describe("sunfish.set_book", function()
    it("returns false for a missing file", function()
        local ok = sunfish.set_book("/nonexistent/book.bin", 1)
        assert_false(ok)
    end)

    it("loads the shipped book and reports the entry count", function()
        local ok, n = sunfish.set_book("benchmarks/sunfish.bin", 1)
        assert_true(ok)
        assert_true(n and n > 0)
    end)

    it("disables the book with a nil path", function()
        sunfish.set_book("benchmarks/sunfish.bin", 1)
        assert_true(sunfish.set_book(nil) == true)
    end)
end)

describe("ai_move with book", function()
    it("returns a legal varied first move from the start", function()
        sunfish.set_book("benchmarks/sunfish.bin", 42)
        -- ai_move returns the CHILD-FRAME display (mirror of the real move);
        -- mirror it back to get the real-board move, then check legality.
        local function real(mv)
            local p1, p2 = mv:sub(1, 2), mv:sub(3, 4)
            local function cell(name)
                local f, r = name:sub(1, 1), tonumber(name:sub(2, 2))
                return 92 + (f:byte() - 97) - 10 * (r - 1)
            end
            local a, b = cell(p1), cell(p2)
            a, b = 121 - a, 121 - b
            local function render(i)
                local rank, fil = math.floor((i - 92) / 10), (i - 92) % 10
                return string.char(fil + string.byte("a")) .. tostring(-rank + 1)
            end
            return render(a) .. render(b)
        end
        local legal = {}
        for _, m in ipairs(sunfish.legal_moves_uci(sunfish.new())) do
            legal[m] = true
        end
        local seen = {}
        for _ = 1, 20 do
            local game = sunfish.new()
            local ng, mv, sc = ai_move(game)
            assert_true(mv ~= nil, "book should return a move from the start")
            local realmv = real(mv)
            assert_true(legal[realmv], "book move " .. tostring(mv) ..
                        " (real " .. realmv .. ") is not a legal start move")
            seen[realmv] = true
            assert_table(ng)
            assert_equal(sc, 0)
        end
        local n = 0
        for _ in pairs(seen) do n = n + 1 end
        assert_true(n > 1, "expected varied first moves, got " .. n)
    end)

    it("returns a legal black move after 1.e4", function()
        sunfish.set_book("benchmarks/sunfish.bin", 7)
        -- black to move after 1.e4: for black, ai_move returns the REAL-board
        -- move (frame == mirrored real, so no child mirror). Verify the reply
        -- is one of black's known legal replies to 1.e4.
        local game = sunfish.new()
        game = sunfish.move(game, "e2e4")
        local ng, mv, sc = ai_move(game)
        assert_true(mv ~= nil, "book should return a black reply")
        local ok = false
        for _, cand in ipairs({ "e7e5", "c7c5", "e7e6", "g8f6", "b8c6", "d7d5" }) do
            if mv:sub(1, 4) == cand then ok = true end
        end
        assert_true(ok, "book black reply " .. tostring(mv) .. " is not a known reply to 1.e4")
    end)
end)

require("tests.harness").finish()
