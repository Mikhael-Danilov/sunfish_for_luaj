-- sunfish.lua, a human transpiler work of https://github.com/thomasahle/sunfish
-- Code License: BSD

-- Localize global functions for massive performance gains in Luaj interpreter mode
local math_floor = math.floor
local math_abs = math.abs
local table_sort = table.sort
local string_sub = string.sub
local string_byte = string.byte
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
-- Integer board representation
--
-- The engine's public API exposes `Position.board` as a 120-char string (as
-- documented and used by the tests), but under LuaJ every string_sub/byte is a
-- Java call. The hot path therefore uses a 120-element Lua array `_b` of
-- integer piece codes, and the string is materialized lazily only at public
-- API boundaries:
--
--   0     empty square ('.')
--   1..6  our pieces P,N,B,R,Q,K  (side to move, uppercase)
--  -1..-6 enemy pieces p,n,b,r,q,k (lowercase)
--   98    padding row '\n'
--   99    padding ' '
--
-- Indexing is unchanged (A1=91, H1=98, A8=21, H8=28, 0..119), so all public
-- coordinate helpers and tests keep working.
-------------------------------------------------------------------------------

-- Piece codes. NOTE: `N` (knight) is named KN to avoid colliding with the
-- direction constant N=-10 used throughout the engine.
local EMPTY, P, KN, B, R, Q, K = 0, 1, 2, 3, 4, 5, 6
local NL, SP = 98, 99
local OUT_OR_BAD = { [98]=true, [99]=true }

-- ASCII byte -> piece code (for lazy string -> array conversion).
local byte_to_code = {}
for _i = 0, 255 do byte_to_code[_i] = EMPTY end
byte_to_code[string.byte('.')] = EMPTY
byte_to_code[string.byte('P')] = P
byte_to_code[string.byte('N')] = KN
byte_to_code[string.byte('B')] = B
byte_to_code[string.byte('R')] = R
byte_to_code[string.byte('Q')] = Q
byte_to_code[string.byte('K')] = K
byte_to_code[string.byte('p')] = -P
byte_to_code[string.byte('n')] = -KN
byte_to_code[string.byte('b')] = -B
byte_to_code[string.byte('r')] = -R
byte_to_code[string.byte('q')] = -Q
byte_to_code[string.byte('k')] = -K
byte_to_code[string.byte(' ')] = SP
byte_to_code[string.byte('\n')] = NL

-- Piece code -> single-char string (for array -> string materialization).
local code_to_char = {}
code_to_char[EMPTY] = '.'
code_to_char[P] = 'P'; code_to_char[-P] = 'p'
code_to_char[KN] = 'N'; code_to_char[-KN] = 'n'
code_to_char[B] = 'B'; code_to_char[-B] = 'b'
code_to_char[R] = 'R'; code_to_char[-R] = 'r'
code_to_char[Q] = 'Q'; code_to_char[-Q] = 'q'
code_to_char[K] = 'K'; code_to_char[-K] = 'k'
code_to_char[SP] = ' '
code_to_char[NL] = '\n'

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

-- Integer aliases so the hot path indexes by piece code (P=1..K=6).
directions[P] = directions['P']
directions[KN] = directions['N']
directions[B] = directions['B']
directions[R] = directions['R']
directions[Q] = directions['Q']
directions[K] = directions['K']
pst[P] = pst['P']
pst[KN] = pst['N']
pst[B] = pst['B']
pst[R] = pst['R']
pst[Q] = pst['Q']
pst[K] = pst['K']

-- The old string-keyed maps (is_upper_map/is_lower_map/swap_map) are replaced
-- by the integer codes: p >= 1 means our piece, p < 0 means enemy, -p is the
-- enemy's piece type.

local Position = {}
Position.__index = Position -- Using a Metatable is ~5x faster in luaj than loop-copying methods!

-- Public constructor: accepts a string board (backward compatible).
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

-- Internal constructor: position with an integer array board (_b).
function Position.from_array(b, score, wc, bc, ep, kp)
    local self = setmetatable({}, Position)
    self._b = b
    self.score = score
    self.wc = wc
    self.bc = bc
    self.ep = ep
    self.kp = kp
    return self
end

-- Build the integer array from the string board (lazy, once).
function Position:ensure_arr()
    local b = self._b
    if not b then
        b = {}
        local board = self.board
        local b2c = byte_to_code
        for i = 0, 119 do
            b[i] = b2c[string.byte(board, i + 1)]
        end
        self._b = b
    end
    return b
end

-- Materialize the string board from the integer array (lazy, once).
function Position:ensure_board()
    if not self.board then
        local b = self._b
        local c2c = code_to_char
        local parts = {}
        for i = 0, 119 do
            parts[i + 1] = c2c[b[i]]
        end
        self.board = table.concat(parts)
    end
    return self.board
end

function Position:genMoves()
    local moves = {}
    local move_idx = 1
    local b = self:ensure_arr()

    for i = 0, 119 do
        local p = b[i]
        if p >= P and p <= K and directions[p] then
            for _, d in ipairs(directions[p]) do
                local j = i + d
                -- Inline sliding check avoiding `limit` math and `isspace` function call
                while true do
                    local q = b[j]
                    if q == SP or q == NL then break end

                    -- Castling
                    if i == A1 and q == K and self.wc[1] then
                        moves[move_idx] = { j, j - 2, 0 }; move_idx = move_idx + 1
                    end
                    if i == H1 and q == K and self.wc[2] then
                        moves[move_idx] = { j, j + 2, 0 }; move_idx = move_idx + 1
                    end

                    if q >= P and q <= K then break end

                    -- Special pawn stuff
                    if p == P then
                        if (d == N + W or d == N + E) and q == EMPTY and j ~= self.ep and j ~= self.kp then break end
                        if (d == N or d == 2 * N) and q ~= EMPTY then break end
                        if d == 2 * N and (i < A1 + N or b[i + N] ~= EMPTY) then break end
                    end

                    moves[move_idx] = { i, j, 0 }; move_idx = move_idx + 1

                    if p == P or p == KN or p == K then break end
                    if q < 0 then break end

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

local knight_dirs = directions['N']
local king_dirs = directions['K']
local pawn_cap_dirs = { N + W, N + E }
-- Sliding attack directions: {delta, rook_code, bishop_code}
local slider_dirs = {
    { N, -R, -Q }, { E, -R, -Q }, { S, -R, -Q }, { W, -R, -Q },
    { N + E, -B, -Q }, { S + E, -B, -Q }, { S + W, -B, -Q }, { N + W, -B, -Q }
}

-- Is square `i` attacked by any opponent (lowercase) piece?
-- `i` is 0-indexed as in genMoves. Works on the integer array `_b`.
function Position:attacked(i)
    local b = self:ensure_arr()

    -- King attacks (opponent kings)
    for _, d in ipairs(king_dirs) do
        local j = i + d
        if b[j] == -K then return true end
    end

    -- Knight attacks
    for _, d in ipairs(knight_dirs) do
        local j = i + d
        if b[j] == -KN then return true end
    end

    -- Pawn attacks: an enemy pawn attacks square i along one diagonal. The
    -- engine rotates the board after every move, so the enemy pawn's "forward"
    -- can point toward index 0 (white frame) or index 119 (black frame).
    -- Checking both diagonals is safe: in a legal position an enemy pawn can
    -- only be on one diagonal from i, and the other can't be occupied by a
    -- pawn (it would be behind the pawn).
    for _, d in ipairs(pawn_cap_dirs) do
        local j = i - d
        if b[j] == -P then return true end
        j = i + d
        if b[j] == -P then return true end
    end

    -- Sliding pieces (rook, bishop, queen)
    for k = 1, 8 do
        local s = slider_dirs[k]
        local d = s[1]
        local r, bb = s[2], s[3]
        local j = i + d
        while true do
            local q = b[j]
            if q == SP or q == NL then break end
            if q == r or q == bb then return true end
            if q ~= EMPTY then break end
            j = j + d
        end
    end

    return false
end

-- Is the side to move in check? (own king is code K)
function Position:in_check()
    local b = self:ensure_arr()
    for i = 0, 119 do
        if b[i] == K then
            return self:attacked(i)
        end
    end
    return false
end

-- Find the index of the side-to-move's king, or nil.
function Position:king_index()
    local b = self:ensure_arr()
    for i = 0, 119 do
        if b[i] == K then
            return i
        end
    end
    return nil
end

-- Is the given pseudo-legal move legal? Applies the move in place on the
-- integer array, tests the own king, then undoes it.
-- `king` (optional) is the precomputed index of the own king.
function Position:is_legal(move, king)
    local i, j = move[1], move[2]
    local b = self:ensure_arr()
    local p = b[i]
    local q = b[j]

    -- Standard chess has no king captures.
    if q == -K then
        return false
    end

    if not king then
        king = self:king_index()
    end

    if p ~= K then
        -- Non-king move: the king stays at `king`.
        b[i] = EMPTY
        b[j] = p
        local ep_undo = false
        if p == P and ((j - i) == N + W or (j - i) == N + E) and q == EMPTY then
            -- en passant: capture the pawn behind the destination
            b[j + S] = EMPTY
            ep_undo = true
        end
        local legal = not self:attacked(king)
        -- undo
        b[i] = p
        b[j] = q
        if ep_undo then
            b[j + S] = -P
        end
        return legal
    end

    -- King move: destination (and castling intermediate square) must not be
    -- attacked.
    if math_abs(j - i) == 2 then
        -- Castling. Replicate the original construction exactly: i emptied,
        -- between holds the KING, j holds the ROOK (the original put K at j
        -- then overwrote j with R), and the rook's origin square is left
        -- untouched. Attack-tests between and j.
        local between = j < i and i - 1 or i + 1
        b[i] = EMPTY
        b[between] = K
        b[j] = R
        local legal
        if self:attacked(between) then
            legal = false
        else
            legal = not self:attacked(j)
        end
        -- undo
        b[i] = K
        b[between] = EMPTY
        b[j] = q
        return legal
    end

    b[i] = EMPTY
    b[j] = K
    local legal = not self:attacked(j)
    b[i] = K
    b[j] = q
    return legal
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
    -- One pass over the integer array: reverse (k -> 119-k) and negate the
    -- piece codes (case swap). Padding codes are untouched.
    local b = self:ensure_arr()
    local nb = {}
    for k = 0, 119 do
        local v = b[119 - k]
        if v < 0 then
            nb[k] = -v
        elseif v > 6 then
            nb[k] = v
        else
            nb[k] = -v
        end
    end
    return Position.from_array(nb, -self.score, self.bc, self.wc, 119 - self.ep, 119 - self.kp)
end

function Position:move(move)
    local i, j = move[1], move[2]
    local b = self:ensure_arr()
    local p = b[i]
    local q = b[j]

    local score = self.score + self:value(move)
    local wc, bc, ep, kp = self.wc, self.bc, 0, 0

    -- Build the moved (un-rotated) board by copying the array and editing.
    local mb = {}
    for k = 0, 119 do mb[k] = b[k] end
    mb[j] = p
    mb[i] = EMPTY

    if i == A1 then wc = { false, wc[2] } end
    if i == H1 then wc = { wc[1], false } end
    if j == A8 then bc = { bc[1], false } end
    if j == H8 then bc = { false, bc[2] } end

    if p == K then
        wc = { false, false }
        if math_abs(j - i) == 2 then
            kp = math_floor((i + j) / 2)
            mb[j < i and A1 or H1] = EMPTY
            mb[kp] = R
        end
    end

    if p == P then
        if A8 <= j and j <= H8 then
            mb[j] = Q -- promotion
        end
        if j - i == 2 * N then
            ep = i + N
        end
        if ((j - i) == N + W or (j - i) == N + E) and q == EMPTY then
            mb[j + S] = EMPTY -- en passant
        end
    end

    -- Rotate the moved board into the new frame in one pass.
    local nb = {}
    for k = 0, 119 do
        local v = mb[119 - k]
        if v < 0 then
            nb[k] = -v
        elseif v > 6 then
            nb[k] = v
        else
            nb[k] = -v
        end
    end
    return Position.from_array(nb, -score, bc, wc, 119 - ep, 119 - kp)
end

function Position:value(move)
    local i, j = move[1], move[2]
    local b = self:ensure_arr()
    local p = b[i]
    local q = b[j]

    local score = pst[p][j + 1] - pst[p][i + 1]
    if q < 0 then
        score = score + pst[-q][j + 1] -- captured piece's PST value
    end

    if math_abs(j - self.kp) < 2 then
        score = score + pst[K][j + 1]
    end

    if p == K and math_abs(i - j) == 2 then
        score = score + pst[R][math_floor((i + j) / 2) + 1]
        score = score - pst[R][j < i and A1 + 1 or H1 + 1]
    end

    if p == P then
        if A8 <= j and j <= H8 then
            score = score + pst[Q][j + 1] - pst[P][j + 1]
        end
        if j == self.ep then
            score = score + pst[P][j + S + 1]
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
    local hash = pos:ensure_board() .. pos.score .. w1 .. w2 .. b1 .. b2 .. pos.ep .. pos.kp

    tp[hash] = val
    tp_count = tp_count + 1
    tp_index[tp_count] = hash
end

local function tp_get(pos)
    local b1 = pos.bc[1] and 1 or 0
    local b2 = pos.bc[2] and 1 or 0
    local w1 = pos.wc[1] and 1 or 0
    local w2 = pos.wc[2] and 1 or 0
    local hash = pos:ensure_board() .. pos.score .. w1 .. w2 .. b1 .. b2 .. pos.ep .. pos.kp
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
    -- Materialize the string board and skip internal `_`-prefixed fields so
    -- the serialized shape stays board/score/wc/bc/ep/kp.
    game:ensure_board()
    local dta = {}
    for k, v in pairs(game) do
        if type(v) ~= 'function' and not (type(k) == 'string' and k:sub(1, 1) == '_') then
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
        local ng = game:move(move)
        ng:ensure_board()
        return ng
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
        game:ensure_board()
        return game, nil, score
    end

    game = game:move(move)
    game:ensure_board()

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
