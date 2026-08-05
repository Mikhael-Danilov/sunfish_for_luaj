-- sunfish.lua, a human transpiler work of https://github.com/thomasahle/sunfish
-- Code License: BSD

-- Localize global functions for massive performance gains in Luaj interpreter mode
local math_floor = math.floor
local math_abs = math.abs
local table_insert = table.insert
local table_sort = table.sort
local string_sub = string.sub
local string_byte = string.byte
local string_reverse = string.reverse
local string_gsub = string.gsub
local string_format = string.format

local TABLE_SIZE = 1e6
local NODES_SEARCHED = 10000
local MATE_VALUE = 30000

local A1, H1, A8, H8 = 91, 98, 21, 28
local initial = '         \n' .. --   0 -  9
        '         \n' .. --  10 - 19
        ' rnbqkbnr\n' .. --  20 - 29
        ' pppppppp\n' .. --  30 - 39
        ' ........\n' .. --  40 - 49
        ' ........\n' .. --  50 - 59
        ' ........\n' .. --  60 - 69
        ' ........\n' .. --  70 - 79
        ' PPPPPPPP\n' .. --  80 - 89
        ' RNBQKBNR\n' .. --  90 - 99
        '         \n' .. -- 100 -109
        '          '     -- 110 -119

-------------------------------------------------------------------------------
-- Move and evaluation tables
-------------------------------------------------------------------------------
local N, E, S, W = -10, 1, 10, -1
local directions = {
    P = { N, 2 * N, N + W, N + E },
    N = { 2 * N + E, N + 2 * E, S + 2 * E, 2 * S + E, 2 * S + W, S + 2 * W, N + 2 * W, 2 * N + W },
    B = { N + E, S + E, S + W, N + W },
    R = { N, E, S, W },
    Q = { N, E, S, W, N + E, S + E, S + W, N + W },
    K = { N, E, S, W, N + E, S + E, S + W, N + W }
}

local pst = {
    P = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 198, 198, 198, 198, 198, 198, 198, 198, 0,
          0, 178, 198, 198, 198, 198, 198, 198, 178, 0,
          0, 178, 198, 198, 198, 198, 198, 198, 178, 0,
          0, 178, 198, 208, 218, 218, 208, 198, 178, 0,
          0, 178, 198, 218, 238, 238, 218, 198, 178, 0,
          0, 178, 198, 208, 218, 218, 208, 198, 178, 0,
          0, 178, 198, 198, 198, 198, 198, 198, 178, 0,
          0, 198, 198, 198, 198, 198, 198, 198, 198, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    B = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 797, 824, 817, 808, 808, 817, 824, 797, 0,
          0, 814, 841, 834, 825, 825, 834, 841, 814, 0,
          0, 818, 845, 838, 829, 829, 838, 845, 818, 0,
          0, 824, 851, 844, 835, 835, 844, 851, 824, 0,
          0, 827, 854, 847, 838, 838, 847, 854, 827, 0,
          0, 826, 853, 846, 837, 837, 846, 853, 826, 0,
          0, 817, 844, 837, 828, 828, 837, 844, 817, 0,
          0, 792, 819, 812, 803, 803, 812, 819, 792, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    N = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 627, 762, 786, 798, 798, 786, 762, 627, 0,
          0, 763, 798, 822, 834, 834, 822, 798, 763, 0,
          0, 817, 852, 876, 888, 888, 876, 852, 817, 0,
          0, 797, 832, 856, 868, 868, 856, 832, 797, 0,
          0, 799, 834, 858, 870, 870, 858, 834, 799, 0,
          0, 758, 793, 817, 829, 829, 817, 793, 758, 0,
          0, 739, 774, 798, 810, 810, 798, 774, 739, 0,
          0, 683, 718, 742, 754, 754, 742, 718, 683, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    R = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 1258, 1263, 1268, 1272, 1272, 1268, 1263, 1258, 0,
          0, 1258, 1263, 1268, 1272, 1272, 1268, 1263, 1258, 0,
          0, 1258, 1263, 1268, 1272, 1272, 1268, 1263, 1258, 0,
          0, 1258, 1263, 1268, 1272, 1272, 1268, 1263, 1258, 0,
          0, 1258, 1263, 1268, 1272, 1272, 1268, 1263, 1258, 0,
          0, 1258, 1263, 1268, 1272, 1272, 1268, 1263, 1258, 0,
          0, 1258, 1263, 1268, 1272, 1272, 1268, 1263, 1258, 0,
          0, 1258, 1263, 1268, 1272, 1272, 1268, 1263, 1258, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    Q = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 0,
          0, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 0,
          0, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 0,
          0, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 0,
          0, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 0,
          0, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 0,
          0, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 0,
          0, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 2529, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    K = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 60098, 60132, 60073, 60025, 60025, 60073, 60132, 60098, 0,
          0, 60119, 60153, 60094, 60046, 60046, 60094, 60153, 60119, 0,
          0, 60146, 60180, 60121, 60073, 60073, 60121, 60180, 60146, 0,
          0, 60173, 60207, 60148, 60100, 60100, 60148, 60207, 60173, 0,
          0, 60196, 60230, 60171, 60123, 60123, 60171, 60230, 60196, 0,
          0, 60224, 60258, 60199, 60151, 60151, 60199, 60258, 60224, 0,
          0, 60287, 60321, 60262, 60214, 60214, 60262, 60321, 60287, 0,
          0, 60298, 60332, 60273, 60225, 60225, 60273, 60332, 60298, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
}

-------------------------------------------------------------------------------
-- Chess logic
-------------------------------------------------------------------------------

-- Extremely fast O(1) piece checking and swapping dictionaries mapping strings.
local is_upper_map = { ['P']=true, ['N']=true, ['B']=true, ['R']=true, ['Q']=true, ['K']=true }
local is_lower_map = { ['p']=true, ['n']=true, ['b']=true, ['r']=true, ['q']=true, ['k']=true }
local swap_map = {
    ['P']='p', ['N']='n', ['B']='b', ['R']='r', ['Q']='q', ['K']='k',
    ['p']='P', ['n']='N', ['b']='B', ['r']='R', ['q']='Q', ['k']='K'
}

local Position = {}
Position.__index = Position -- Using a Metatable is ~5x faster in luaj than loop-copying methods!

function Position.new(board, score, wc, bc, ep, kp)
    local self = setmetatable({}, Position)
    self.board = board
    self.score = score
    self.wc = wc
    self.bc = bc
    self.ep = ep
    self.kp = kp
    return self
end

function Position:genMoves()
    local moves = {}
    local move_idx = 1
    local board = self.board

    for i = 0, 119 do
        local p = string_sub(board, i + 1, i + 1)
        if is_upper_map[p] and directions[p] then
            for _, d in ipairs(directions[p]) do
                local j = i + d
                -- Inline sliding check avoiding `limit` math and `isspace` function call
                while true do
                    local q = string_sub(board, j + 1, j + 1)
                    if q == ' ' or q == '\n' then break end

                    -- Castling
                    if i == A1 and q == 'K' and self.wc[1] then
                        moves[move_idx] = { j, j - 2, 0 }; move_idx = move_idx + 1
                    end
                    if i == H1 and q == 'K' and self.wc[2] then
                        moves[move_idx] = { j, j + 2, 0 }; move_idx = move_idx + 1
                    end

                    if is_upper_map[q] then break end

                    -- Special pawn stuff
                    if p == 'P' then
                        if (d == N + W or d == N + E) and q == '.' and j ~= self.ep and j ~= self.kp then break end
                        if (d == N or d == 2 * N) and q ~= '.' then break end
                        if d == 2 * N and (i < A1 + N or string_sub(board, i + N + 1, i + N + 1) ~= '.') then break end
                    end

                    moves[move_idx] = { i, j, 0 }; move_idx = move_idx + 1

                    if p == 'P' or p == 'N' or p == 'K' then break end
                    if is_lower_map[q] then break end

                    j = j + d
                end
            end
        end
    end
    return moves
end

-------------------------------------------------------------------------------
-- Legality: the engine is a *chess* engine, so we enforce real chess rules.
-- A move is legal only if it does not leave the side-to-move's own king in
-- check, and captures of a protected enemy king are rejected (a king may
-- only be captured when the game has already been decided by checkmate).
-- genMoves() stays pseudo-legal for backward compatibility; legal_moves()
-- filters it. Search and public move validation use legal_moves().
-------------------------------------------------------------------------------

-- Replace the character at 1-based position i in board string.
local function put(board, i, p)
    return string_sub(board, 1, i - 1) .. p .. string_sub(board, i + 1)
end

local knight_dirs = directions['N']
local king_dirs = directions['K']
local pawn_cap_dirs = { N + W, N + E }
-- Sliding attack directions: {delta, rook_piece, bishop_piece}
local slider_dirs = {
    { N, 'r', 'q' }, { E, 'r', 'q' }, { S, 'r', 'q' }, { W, 'r', 'q' },
    { N + E, 'b', 'q' }, { S + E, 'b', 'q' }, { S + W, 'b', 'q' }, { N + W, 'b', 'q' }
}

-- Is square `i` attacked by any opponent (lowercase) piece?
-- `i` is 0-indexed as in genMoves.
function Position:attacked(i)
    local board = self.board

    -- King attacks (opponent kings, lowercase)
    for _, d in ipairs(king_dirs) do
        local j = i + d
        local q = string_sub(board, j + 1, j + 1)
        if q == 'k' then return true end
    end

    -- Knight attacks
    for _, d in ipairs(knight_dirs) do
        local j = i + d
        local q = string_sub(board, j + 1, j + 1)
        if q == 'n' then return true end
    end

    -- Pawn attacks: an enemy pawn attacks square i along one diagonal. The
    -- engine rotates the board after every move, so the enemy pawn's "forward"
    -- can point toward index 0 (white frame) or index 119 (black frame).
    -- Checking both diagonals is safe: in a legal position an enemy pawn can
    -- only be on one diagonal from i, and the other can't be occupied by a
    -- pawn (it would be behind the pawn).
    for _, d in ipairs(pawn_cap_dirs) do
        local j = i - d
        if string_sub(board, j + 1, j + 1) == 'p' then return true end
        j = i + d
        if string_sub(board, j + 1, j + 1) == 'p' then return true end
    end

    -- Sliding pieces (rook, bishop, queen)
    for k = 1, 8 do
        local s = slider_dirs[k]
        local d, r, b = s[1], s[2], s[3]
        local j = i + d
        while true do
            local q = string_sub(board, j + 1, j + 1)
            if q == ' ' or q == '\n' then break end
            if q == r or q == b then return true end
            if q ~= '.' then break end
            j = j + d
        end
    end

    return false
end

-- Is the side to move in check? (own king is uppercase 'K')
function Position:in_check()
    local board = self.board
    for i = 0, 119 do
        if string_sub(board, i + 1, i + 1) == 'K' then
            return self:attacked(i)
        end
    end
    return false
end

-- Find the index of the side-to-move's king, or nil.
function Position:king_index()
    local board = self.board
    for i = 0, 119 do
        if string_sub(board, i + 1, i + 1) == 'K' then
            return i
        end
    end
    return nil
end

-- Is the given pseudo-legal move legal? Applies the move to a copy, then
-- checks the own king is not attacked in the resulting (un-rotated) board.
-- We must apply the move *before* rotate() to see the un-rotated board, so
-- we replicate move()'s board edits on a local string.
-- `king` (optional) is the precomputed index of the own king.
function Position:is_legal(move, king)
    local i, j = move[1], move[2]
    local board = self.board
    local p = string_sub(board, i + 1, i + 1)
    local q = string_sub(board, j + 1, j + 1)

    -- Standard chess has no king captures.
    if q == 'k' then
        return false
    end

    if not king then
        king = self:king_index()
    end

    -- If we are not moving the king, the king stays at `king`; check whether
    -- the moved piece leaves it exposed. En passant and castling do not apply
    -- here (a pawn capture of a king is already excluded; the king only moves
    -- when it is the moving piece).
    if p ~= 'K' then
        -- The king stays at `king`; rebuild the board with the move applied
        -- and test whether the king is attacked.
        local moved = put(board, i + 1, '.')
        moved = put(moved, j + 1, p)
        -- en passant: the captured pawn sits behind the destination
        if p == 'P' and ((j - i) == N + W or (j - i) == N + E) and q == '.' then
            moved = put(moved, j + S + 1, '.')
        end
        local tmp = setmetatable({ board = moved }, Position)
        return not tmp:attacked(king)
    end

    -- King move: the destination (and castling intermediate square) must not
    -- be attacked.
    local moved = put(board, i + 1, '.')
    moved = put(moved, j + 1, 'K')
    if math_abs(j - i) == 2 then
        -- castling: move the rook and check the intermediate square
        local between = j < i and i - 1 or i + 1
        moved = put(moved, between + 1, 'K')
        moved = put(moved, j + 1, 'R')
        local tmp = setmetatable({ board = moved }, Position)
        if tmp:attacked(between) then return false end
        return not tmp:attacked(j)
    end
    local tmp = setmetatable({ board = moved }, Position)
    return not tmp:attacked(j)
end

-- All legal moves (filtered from pseudo-legal genMoves).
function Position:legal_moves()
    local pseudo = self:genMoves()
    local legal = {}
    local n = 0
    local king = self:king_index()
    for _, m in ipairs(pseudo) do
        if self:is_legal(m, king) then
            n = n + 1
            legal[n] = m
        end
    end
    return legal
end

-- Checkmate: in check and no legal moves. Stalemate: not in check and no
-- legal moves.
function Position:is_checkmate()
    if not self:in_check() then return false end
    return #self:legal_moves() == 0
end

function Position:is_stalemate()
    if self:in_check() then return false end
    return #self:legal_moves() == 0
end

function Position:rotate()
    -- string.gsub scales massively better than iterating string chars in luaj.
    local rev = string_reverse(self.board)
    local swp = string_gsub(rev, ".", swap_map)
    return Position.new(swp, -self.score, self.bc, self.wc, 119 - self.ep, 119 - self.kp)
end

function Position:move(move)
    local i, j = move[1], move[2]
    local p = string_sub(self.board, i + 1, i + 1)
    local q = string_sub(self.board, j + 1, j + 1)

    local score = self.score + self:value(move)
    local board = self.board
    local wc, bc, ep, kp = self.wc, self.bc, 0, 0

    board = put(board, j + 1, p)
    board = put(board, i + 1, '.')

    if i == A1 then wc = { false, wc[2] } end
    if i == H1 then wc = { wc[1], false } end
    if j == A8 then bc = { bc[1], false } end
    if j == H8 then bc = { false, bc[2] } end

    if p == 'K' then
        wc = { false, false }
        if math_abs(j - i) == 2 then
            kp = math_floor((i + j) / 2)
            board = put(board, j < i and A1 + 1 or H1 + 1, '.')
            board = put(board, kp + 1, 'R')
        end
    end

    if p == 'P' then
        if A8 <= j and j <= H8 then
            board = put(board, j + 1, 'Q')
        end
        if j - i == 2 * N then
            ep = i + N
        end
        if ((j - i) == N + W or (j - i) == N + E) and q == '.' then
            board = put(board, j + S + 1, '.')
        end
    end

    return Position.new(board, score, wc, bc, ep, kp):rotate()
end

function Position:value(move)
    local i, j = move[1], move[2]
    local p = string_sub(self.board, i + 1, i + 1)
    local q = string_sub(self.board, j + 1, j + 1)

    local score = pst[p][j + 1] - pst[p][i + 1]
    if is_lower_map[q] then
        score = score + pst[swap_map[q]][j + 1] -- Fast string swapping logic without O(N) allocation
    end

    if math_abs(j - self.kp) < 2 then
        score = score + pst['K'][j + 1]
    end

    if p == 'K' and math_abs(i - j) == 2 then
        score = score + pst['R'][math_floor((i + j) / 2) + 1]
        score = score - pst['R'][j < i and A1 + 1 or H1 + 1]
    end

    if p == 'P' then
        if A8 <= j and j <= H8 then
            score = score + pst['Q'][j + 1] - pst['P'][j + 1]
        end
        if j == self.ep then
            score = score + pst['P'][j + S + 1]
        end
    end
    return score
end

local tp = {}
local tp_index = {}
local tp_count = 0

local function tp_set(pos, val)
    -- Simplified and fixed transposition hashing.
    -- 1. Using numbers directly avoids concatenating boolean 't' and 'f' strings in Lua.
    -- 2. Fixed critical bug in original engine where w1 & w2 looked at 'pos.bc' instead of 'pos.wc'
    local b1 = pos.bc[1] and 1 or 0
    local b2 = pos.bc[2] and 1 or 0
    local w1 = pos.wc[1] and 1 or 0
    local w2 = pos.wc[2] and 1 or 0
    local hash = pos.board .. pos.score .. w1 .. w2 .. b1 .. b2 .. pos.ep .. pos.kp

    tp[hash] = val
    tp_count = tp_count + 1
    tp_index[tp_count] = hash
end

local function tp_get(pos)
    local b1 = pos.bc[1] and 1 or 0
    local b2 = pos.bc[2] and 1 or 0
    local w1 = pos.wc[1] and 1 or 0
    local w2 = pos.wc[2] and 1 or 0
    local hash = pos.board .. pos.score .. w1 .. w2 .. b1 .. b2 .. pos.ep .. pos.kp
    return tp[hash]
end

local function tp_popitem()
    tp[tp_index[tp_count]] = nil
    tp_index[tp_count] = nil
    tp_count = tp_count - 1
end

-------------------------------------------------------------------------------
-- Search logic
-------------------------------------------------------------------------------

local nodes = 0

local function bound(pos, gamma, depth)
    nodes = nodes + 1
    if nodes % 30 == 0 then coroutine.yield() end

    if math_abs(pos.score) >= MATE_VALUE then
        return pos.score
    end

    -- Generate pseudo-legal moves and filter out those that leave our own king
    -- in check. If no legal move exists the position is checkmate or stalemate.
    -- This must happen BEFORE the TT lookup so mated/stalemated positions
    -- always evaluate to the terminal score (a stale TT entry could otherwise
    -- mask the mate).
    local pseudo = pos:genMoves()
    local moves = {}
    local nlegal = 0
    local king = pos:king_index()
    for k = 1, #pseudo do
        local move = pseudo[k]
        if pos:is_legal(move, king) then
            nlegal = nlegal + 1
            moves[nlegal] = move
        end
    end
    if nlegal == 0 then
        if pos:in_check() then
            return -MATE_VALUE -- checkmate: side to move loses
        else
            return 0 -- stalemate
        end
    end

    local entry = tp_get(pos)
    if entry ~= nil and entry.depth >= depth and (
            entry.score < entry.gamma and entry.score < gamma or
                    entry.score >= entry.gamma and entry.score >= gamma) then
        return entry.score
    end

    local nullscore = depth > 0 and -bound(pos:rotate(), 1 - gamma, depth - 3) or pos.score
    if nullscore >= gamma then
        return nullscore
    end

    local best, bmove = -3 * MATE_VALUE, nil

    -- Cache calculated move values so table.sort doesn't repeatedly call `pos:value()` $O(N \log N)$ times
    for k = 1, nlegal do
        moves[k][3] = pos:value(moves[k])
    end

    local function sorter(a, b)
        if a[3] ~= b[3] then
            return a[3] > b[3]
        else
            if a[1] == b[1] then
                return a[2] > b[2]
            else
                return a[1] < b[1]
            end
        end
    end
    table_sort(moves, sorter)

    for k = 1, nlegal do
        local move = moves[k]
        if depth <= 0 and move[3] < 150 then
            break
        end
        local score = -bound(pos:move(move), 1 - gamma, depth - 1)
        if score > best then
            best = score
            bmove = move
        end
        if score >= gamma then
            break
        end
    end

    if depth <= 0 and best < nullscore then
        return nullscore
    end

    if entry == nil or depth >= entry.depth and best >= gamma then
        tp_set(pos, { depth = depth, score = best, gamma = gamma, move = bmove })
        if tp_count > TABLE_SIZE then
            tp_popitem()
        end
    end
    return best
end

local function search(pos, maxn)
    maxn = maxn or NODES_SEARCHED
    nodes = 0
    local score

    for depth = 1, 98 do
        local lower, upper = -3 * MATE_VALUE, 3 * MATE_VALUE
        while lower < upper - 3 do
            local gamma = math_floor((lower + upper + 1) / 2)
            score = bound(pos, gamma, depth)
            assert(score)
            if score >= gamma then
                lower = score
            end
            if score < gamma then
                upper = score
            end
        end
        assert(score)

        print(string_format("Searched %d nodes. Depth %d. Score %d(%d/%d)", nodes, depth, score, lower, upper))

        if nodes >= maxn or math_abs(score) >= MATE_VALUE then
            break
        end
    end

    local entry = tp_get(pos)
    if entry ~= nil then
        return entry.move, score
    end
    return nil, score
end

-------------------------------------------------------------------------------
-- User interface
-------------------------------------------------------------------------------

local function parse(c)
    if not c then return nil end
    local p, v = string_sub(c, 1, 1), string_sub(c, 2, 2)
    if not (p and v and tonumber(v)) then return nil end

    local fil, rank = string_byte(p) - string_byte('a'), tonumber(v) - 1
    return A1 + fil - 10 * rank
end

local function render(i)
    local rank, fil = math_floor((i - A1) / 10), (i - A1) % 10
    return string.char(fil + string_byte('a')) .. tostring(-rank + 1)
end

local function ttfind(t, k)
    assert(t)
    if not k then return false end
    for _, v in ipairs(t) do
        if k[1] == v[1] and k[2] == v[2] then
            return true
        end
    end
    return false
end

--//RPD interface:

local sunfish = {}

sunfish.MATE_VALUE = MATE_VALUE

local game = Position.new(initial, 0, { true, true }, { true, true }, 0, 0)

function sunfish.new()
    game = Position.new(initial, 0, { true, true }, { true, true }, 0, 0)
    return game
end

function sunfish.store_data(game)
    local dta = {}
    for k, v in pairs(game) do
        if type(v) ~= 'function' then
            dta[k] = v
        end
    end
    return dta
end

function sunfish.restore_data(dta)
    game = setmetatable({}, Position)
    for k,v in pairs(dta) do
        game[k] = v
    end
    return game
end

function sunfish.move(game, mv)
    local move = { parse(string_sub(mv, 1, 2)), parse(string_sub(mv, 3, 4)) }
    if move[1] and move[2] and ttfind(game:legal_moves(), move) then
        return game:move(move)
    else
        return false
    end
end

function sunfish.ai_move(game)
    local move, score = search(game)

    assert(score)
    if not move then
        -- Search converged to a mate/stalemate without a move (the root is
        -- already decided). Return the position unchanged and the score.
        return game, nil, score
    end

    game = game:move(move)

    return game, render(119 - move[1]) .. render(119 - move[2]), score
end

-- Position query helpers (backward-compatible additions).
function sunfish.in_check(game)
    return game:in_check()
end

function sunfish.is_checkmate(game)
    return game:is_checkmate()
end

function sunfish.is_stalemate(game)
    return game:is_stalemate()
end

function sunfish.legal_moves(game)
    return game:legal_moves()
end

function sunfish.move_2_cell(cell)
    return render(cell)
end

function sunfish.cell_2_move(move)
    return parse(string_sub(move, 1, 2))
end

return sunfish
