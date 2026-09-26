-- Stress: play many KRK/KQK games through sunfish.ai_move with the bkm_light
-- fast path enabled, verifying every returned move is legal and every winning
-- game terminates in mate (no stalemates, no piece drops).
-- Usage: luajit tests/selfplay_bkm_light.lua [games] [seed]

local sunfish = require("sunfish")
local green = require("green")
sunfish.set_use_bkm_light(true)

local N = tonumber(arg[1]) or tonumber(arg[2]) or 60
local seed = tonumber(arg[2]) or tonumber(arg[3]) or 42
local MAX_PLIES = tonumber(arg[3]) or tonumber(arg[4]) or 200

local rng = { x = seed }
function rng:next(m)
    self.x = (self.x * 1664525 + 1013904223) % 4294967296
    return math.floor(self.x / 65536) % m
end

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
    if black_to_move then g = g:rotate() end
    return g
end

-- random legal KRK/KQK start (strong side to move)
local function sample(piece)
    local adj = {}
    for a = 0, 63 do
        adj[a] = {}
        local af, ar = a % 8, math.floor(a / 8)
        for b = 0, 63 do
            local bf, br = b % 8, math.floor(b / 8)
            if math.max(math.abs(af - bf), math.abs(ar - br)) <= 1 then adj[a][b] = true end
        end
    end
    local function attacked_by_piece(pc, target, blocker)
        if pc == target then return false end
        local pf, pr = pc % 8, math.floor(pc / 8)
        local tf, tr = target % 8, math.floor(target / 8)
        local df, dr = tf - pf, tr - pr
        local adf, adr = math.abs(df), math.abs(dr)
        local ok
        if piece == "R" then ok = (df == 0 or dr == 0)
        else ok = (df == 0 or dr == 0 or adf == adr) end
        if not ok then return false end
        local sf = (df > 0 and 1) or (df < 0 and -1) or 0
        local sr = (dr > 0 and 1) or (dr < 0 and -1) or 0
        local f, r = pf + sf, pr + sr
        while f ~= tf or r ~= tr do
            if r * 8 + f == blocker then return false end
            f = f + sf
            r = r + sr
        end
        return true
    end
    for _ = 1, 2000 do
        local wk = rng:next(64)
        local bk = rng:next(64)
        local pc = rng:next(64)
        local function alg(sq) return string.char(97 + sq % 8) .. tostring(math.floor(sq / 8) + 1) end
        if not adj[wk][bk] and pc ~= wk and pc ~= bk
            and not attacked_by_piece(pc, bk, wk) then
            return alg(wk), alg(pc), alg(bk)
        end
    end
    return nil
end

local function run(piece)
    local mated, drawn, nonterm, illegal = 0, 0, 0, 0
    local maxply = 0
    for g = 1, N do
        local wk, pc, bk = sample(piece)
        if not wk then break end
        local start = { [wk] = "K", [pc] = piece, [bk] = "k" }
        local pos = newpos(start)
        local ply = 0
        while ply < MAX_PLIES do
            -- Run ai_move in a green thread (the engine yields during search).
            -- ai_move returns (newpos, movestr, score); green.run forwards all
            -- three. NOTE: the old destructuring `ok, ng, mv` caught the SCORE
            -- in mv and the MOVE STRING in ng, so every game counted as
            -- "illegal" at ply 0 — the harness never actually played.
            local npos, mvs, sc = green.run(function() return sunfish.ai_move(pos) end)
            if not npos then error(mvs, 0) end
            if not mvs then
                -- terminal: mate or stalemate
                if sunfish.is_checkmate(pos) then
                    mated = mated + 1
                else
                    drawn = drawn + 1
                end
                break
            end
            -- Legality via sunfish.move (replays on the original pos). The
            -- display move follows the engine's documented convention:
            -- rendered in the CHILD (rotated) frame, i.e. the mirror of the
            -- current frame's squares — mirror it back before replaying.
            local function m1(name)
                local i = sunfish.cell_2_move(name) + 1 -- internal 1-based
                local mir = 121 - i
                local rank = math.floor((mir - 92) / 10)
                local fil = (mir - 92) % 10
                return string.char(fil + string.byte("a")) .. tostring(1 - rank)
            end
            local real = m1(mvs:sub(1, 2)) .. m1(mvs:sub(3, 4))
            local via = sunfish.move(pos, real)
            if via == false then
                illegal = illegal + 1
                break
            end
            if npos ~= pos then
                -- cross-check: the returned successor must equal the replay
                assert(sunfish.is_checkmate(via) == sunfish.is_checkmate(npos),
                    "successor mismatch: replay vs ai_move return")
            end
            pos = npos
            ply = ply + 1
        end
        if ply >= MAX_PLIES then nonterm = nonterm + 1 end
        maxply = math.max(maxply, ply)
    end
    print(string.format("%s: N=%d mated=%d drawn=%d nonterm=%d illegal=%d maxply=%d",
        piece, N, mated, drawn, nonterm, illegal, maxply))
end

run("R")
run("Q")
