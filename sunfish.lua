-- sunfish.lua, a human transpiler work of https://github.com/thomasahle/sunfish
-- Code License: BSD

-- Localize global functions for massive performance gains in Luaj interpreter mode
local math_floor = math.floor
local math_abs = math.abs
local string_sub = string.sub
local string_byte = string.byte
local string_format = string.format

local NODES_SEARCHED = 10000
local MATE_VALUE = 30000
local TT_SIZE = 65536 -- fixed-size transposition table (bounded memory, ~64k slots)

-- Yield tuning. The search runs inside a coroutine (the Android RPD loop and
-- the test harness drive it) and yields periodically so the caller can poll.
-- Under LuaJ each coroutine.yield() is a JVM context hop (~330 switches per
-- 10k search at the old hardcoded 30-node quantum), so a bigger countdown
-- quantum is measurably faster (~33% at 256, ~41% at 1024; no-yield ~56%).
-- YIELD_QUANTUM is a tunable; the Android layer can lower it for
-- responsiveness or raise it for throughput. YIELD_ENABLED lets the
-- benchmark harness measure the uncapped ceiling (no coroutine switches).
local YIELD_QUANTUM = 256
local YIELD_ENABLED = true
-- Gate the per-depth search progress print. Under LuaJ (and Android log
-- routing) the unconditional print/string_format is expensive; SUNFISH_VERBOSE=1
-- enables it for debugging, otherwise search runs silent.
local VERBOSE = os.getenv("SUNFISH_VERBOSE") == "1"

local A1, H1, A8, H8 = 92, 99, 22, 29
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

-- Packed move encoding. A move is a single integer instead of a {i, j, val}
-- table: value semantics (no aliasing), and genMoves allocates one number per
-- pseudo-legal move instead of one 3-cell table. Layout:
--   low 14 bits  : from-square i * 128 + to-square j   (i,j in 0..119)
--   high bits    : signed sort value, biased by VAL_BIAS (2^22)
-- Pure arithmetic (no bit32/bitwise ops, per the LuaJ-interpreter constraint).
local VAL_SHIFT = 14
local VAL_BIAS = 2 ^ 22 -- half of the 23-bit value field
-- Precomputed constants (Lua 5.1 has no constant folding; `2 ^ VAL_SHIFT` and
-- `128 * 128` were recomputed on every call in the hot path).
local VAL_SCALE = 2 ^ VAL_SHIFT
local MOVE_MOD = 128 * 128
local function move_pack(i, j, val)
    return i * 128 + j + (val + VAL_BIAS) * VAL_SCALE
end
local function move_from(v)
    return math_floor(v / 128) % 128
end
local function move_to(v)
    return v % 128
end
local function move_val(v)
    return math_floor(v / VAL_SCALE) - VAL_BIAS
end
-- Rewrite the value field of a packed move (sorting updates the cached value).
local function move_set_val(v, val)
    return (v % MOVE_MOD) + (val + VAL_BIAS) * VAL_SCALE
end

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

-------------------------------------------------------------------------------
-- Precomputed attack/ray tables
--
-- The 0..119 index space is an 8x8 board padded to 10 columns: cols 0 and 9
-- of each row are spaces (SP) and rows 0/1 and 8/9 are padding, so a square
-- is "on the board" iff 20 <= i < 100 and i%10 is 1..8. Rays step until the
-- edge; the engine's while-loops stop at SP/NL, which is exactly this wall.
-------------------------------------------------------------------------------
local is_on_board = {}
local is_on_board_1 = {} -- 1-based mirror for genMoves (j is a 1-based square)
local real_squares = {} -- the 64 real board squares, stored 1-based (built once)
for _i = 0, 119 do
    is_on_board[_i] = _i >= 20 and _i < 100 and (_i % 10) >= 1 and (_i % 10) <= 8
    if is_on_board[_i] then
        local i1 = _i + 1
        real_squares[#real_squares + 1] = i1
        is_on_board_1[i1] = true
    end
end

-- ray_squares[i][d]: squares along direction d (d in 1..8) from i.
-- knight_targets[i] / king_targets[i] / pawn_caps[i]: fixed move sets.
local ray_squares, knight_targets, king_targets, pawn_caps = {}, {}, {}, {}
local all_dirs = { N, E, S, W, N + E, S + E, S + W, N + W }
local knight_offsets = { 2 * N + E, N + 2 * E, S + 2 * E, 2 * S + E, 2 * S + W, S + 2 * W, N + 2 * W, 2 * N + W }
local king_offsets = { N, E, S, W, N + E, S + E, S + W, N + W }
for i = 0, 119 do
    if is_on_board[i] then
        local t = i + 1
        ray_squares[t] = {}
        for di, d in ipairs(all_dirs) do
            local j = i + d
            local sqs = {}
            local n = 0
            while is_on_board[j] do
                n = n + 1
                sqs[n] = j + 1
                j = j + d
            end
            n = n + 1
            sqs[n] = 0 -- sentinel terminator
            ray_squares[t][di] = sqs
        end
        local kt, kg, pc = {}, {}, {}
        for oi, o in ipairs(knight_offsets) do
            local j = i + o
            if is_on_board[j] then kt[#kt + 1] = j + 1 end
        end
        for oi, o in ipairs(king_offsets) do
            local j = i + o
            if is_on_board[j] then kg[#kg + 1] = j + 1 end
        end
        for _, o in ipairs({ N + W, N + E }) do
            local j = i + o
            if is_on_board[j] then pc[#pc + 1] = j + 1 end
        end
        knight_targets[t] = kt
        king_targets[t] = kg
        pawn_caps[t] = pc
    end
end

-- direction index for each piece: P=1 pawn, KN=2 knight, B=3, R=4, Q=5, K=6
-- pawn: di 1 (N), 2 (2N), 3 (N+W), 4 (N+E) -- we handle pawns specially in genMoves
-- knight: 8 fixed targets
-- sliders: rook di 1..4, bishop di 5..8, queen di 1..8
local slider_dirs_by_piece = {
    [R] = { 1, 2, 3, 4 },
    [B] = { 5, 6, 7, 8 },
    [Q] = { 1, 2, 3, 4, 5, 6, 7, 8 }
}

-------------------------------------------------------------------------------
-- Transposition-table key (integer, cached per Position)
--
-- Pure Lua 5.1 (no bit32 on Android/LuaJ), so we use a Zobrist-style sum of
-- precomputed pseudo-random values. XOR would be ideal, but sum works fine for
-- a 64k-slot table: the stored full key is verified on every probe, so a
-- collision only costs a missed lookup, never a wrong result.
-- The key covers board + castling rights + ep + kp (NOT score: two move orders
-- reaching the same position must share a TT entry).
-------------------------------------------------------------------------------
local zob = {}
local zflat = {}
local zob_wc = { 0, 0 }
local zob_bc = { 0, 0 }
local zob_ep = {}
local zob_kp = {}
do
    -- Deterministic Multiply-With-Carry PRNG. Pure Lua 5.1 arithmetic (no
    -- bit32/bitwise on Android/LuaJ). MWC gives well-distributed low bits,
    -- which matters because the TT slot is key % TT_SIZE (low bits of key).
    -- A bad low-bit PRNG (e.g. LCG) collapses the table into a few slots.
    local x = 88172645463325252 % 65536
    local c = math.floor(88172645463325252 / 65536) % 65536
    local function rnd()
        local t = x * 65539 + c
        c = math.floor(t / 65536)
        x = t % 65536
        return x + c * 65536
    end
    for pc = -6, 6 do
        zob[pc] = {}
        for sq = 0, 119 do
            zob[pc][sq] = rnd()
        end
    end
    -- Flat 1D alias for the hash loop: zflat[(pc+6)*120 + sq] == zob[pc][sq].
    -- A single table get instead of two saves a LuaJ Java call per square.
    zflat = {}
    for pc = -6, 6 do
        for sq = 0, 119 do
            zflat[(pc + 6) * 120 + sq + 1] = zob[pc][sq]
        end
    end
    zob_wc[1], zob_wc[2] = rnd(), rnd()
    zob_bc[1], zob_bc[2] = rnd(), rnd()
    for sq = 0, 119 do
        zob_ep[sq + 1] = rnd()
    end
    zob_ep[121] = 0 -- mirror of the no-ep sentinel (121 - 0)
    zob_kp[1] = 0
    for sq = 1, 119 do
        zob_kp[sq + 1] = rnd()
    end
    zob_kp[121] = 0 -- mirror of the no-kp sentinel (121 - 0)
end

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
-- Optional trailing args thread the cached king indices through search:
--   _king  = index of the side-to-move's king (code K)
--   _eking = index of the enemy king (code -K)
-- These avoid the up-to-120-square scan in king_index()/eking_index() on every
-- fresh search position.
function Position.from_array(b, score, wc, bc, ep, kp, nk, nek)
    local self = setmetatable({}, Position)
    self._b = b
    self.score = score
    self.wc = wc
    self.bc = bc
    self.ep = ep
    self.kp = kp
    self._king = nk
    self._eking = nek
    return self
end

-------------------------------------------------------------------------------
-- Pooled Position/board reuse for the search hot path
--
-- Every bound() node creates a child via move() (and a rotate() child for the
-- null move). In the immutable design those children allocate a fresh 120-slot
-- board + Position object each: measured ~1 board + ~1 object per node
-- (~23k tables + ~11.6k objects per 10k-node search), all short-lived garbage
-- on a GC'd interpreter.
--
-- The children's lifetimes are strictly nested with the recursion: each child
-- is passed to the next bound() frame, fully consumed there (only numbers --
-- scores and packed moves -- escape), and is dead before the next sibling is
-- created. So a simple free-list pool is safe: a pooled slot is only reused
-- after its position has fully returned. The pool is bounded (POOL_CAP slots);
-- beyond that, freed slots drop out and GC reclaims them.
--
-- move()/rotate() take a `pooled` flag: the search passes true, the public API
-- (sunfish.move, ai_move's returned position, tests calling rotate()) passes
-- nothing and keeps allocating fresh.
local POOL_CAP = 1024
local pool_free = {} -- free list of dead Position objects, each still holding its _b

local function pool_alloc()
    local self = pool_free[#pool_free]
    if self then
        pool_free[#pool_free] = nil
        return self, self._b
    end
    local b = {}
    local self = setmetatable({}, Position)
    self._b = b
    return self, b
end

local function pool_free_pos(self)
    -- Drop all fields so a stale reference can never alias a live board; the
    -- board (_b) stays on the object so it is reused with the slot.
    self.board = nil
    self._key = nil
    self._king = nil
    self._eking = nil
    self.score = nil
    self.wc = nil
    self.bc = nil
    self.ep = nil
    self.kp = nil
    if #pool_free < POOL_CAP then
        pool_free[#pool_free + 1] = self
    end
end

-- Compute (and cache) the integer key for a position. The key is stored on the
-- position as `_key` so it is computed once per position, not per TT probe.
-- NOTE: an incremental (O(1)) dual-hash key was implemented and verified
-- correct on every move/rotate path, but reverted: the search exposes a
-- pre-existing `_b` corruption (an extra pawn leaks into a pooled child via a
-- path the per-call key() masked by re-hashing `_b`), so a cached board hash
-- is unsafe (node counts 11651 vs 11653 baseline). The full 120-pass re-hashes
-- the current `_b` and is immune. See the doc's Post-Phase-9 review.
function Position:key()
    local k = self._key
    if not k then
        local b = self._b or self:ensure_arr()
        local zf = zflat
        local h = 0
        for i = 1, 120 do
            local pc = b[i]
            -- Skip empty squares and the padding codes (98/99); only pieces hash.
            if pc ~= EMPTY and pc ~= SP and pc ~= NL then h = h + zf[(pc + 6) * 120 + i] end
        end
        if self.wc[1] then h = h + zob_wc[1] end
        if self.wc[2] then h = h + zob_wc[2] end
        if self.bc[1] then h = h + zob_bc[1] end
        if self.bc[2] then h = h + zob_bc[2] end
        if self.ep ~= 0 then h = h + zob_ep[self.ep] end
        if self.kp ~= 0 then h = h + zob_kp[self.kp] end
        k = h % 4294967296 -- keep it a 32-bit-range integer for cheap math
        self._key = k
    end
    return k
end

-- Build the integer array from the string board (lazy, once).
function Position:ensure_arr()
    local b = self._b
    if not b then
        b = {}
        local board = self.board
        local b2c = byte_to_code
        for i = 1, 120 do
            b[i] = b2c[string.byte(board, i)]
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
        for i = 1, 120 do
            parts[i] = c2c[b[i]]
        end
        self.board = table.concat(parts)
    end
    return self.board
end

function Position:genMoves(out, start)
    local moves = out or {}
    local move_idx = start or 1
    local b = self:ensure_arr()
    local wc1, wc2 = self.wc[1], self.wc[2]
    local ep, kp = self.ep, self.kp

    for si = 1, 64 do
        local i = real_squares[si]
        local p = b[i]
        if p >= P and p <= K then
            if p == P then
                -- Pawn: single push, double push, captures, ep.
                local j = i + N
                if is_on_board_1[j] and b[j] == EMPTY then
                    moves[move_idx] = move_pack(i, j, 0); move_idx = move_idx + 1
                    -- Double push: original allows it whenever i >= A1+N and
                    -- the intermediate square is empty (the single push above
                    -- already verified b[i+N]==EMPTY). The last-rank special
                    -- case (e.g. a pawn on e1) is preserved.
                    if i >= A1 + N then
                        local j2 = i + 2 * N
                        if is_on_board_1[j2] and b[j2] == EMPTY then
                            moves[move_idx] = move_pack(i, j2, 0); move_idx = move_idx + 1
                        end
                    end
                end
                -- Captures (diagonals). En passant when the target is empty but is ep.
                local pc = pawn_caps[i]
                for c = 1, #pc do
                    j = pc[c]
                    local q = b[j]
                    if q < 0 or (q == EMPTY and j == ep) then
                        moves[move_idx] = move_pack(i, j, 0); move_idx = move_idx + 1
                    end
                end
            elseif p == KN then
                local kt = knight_targets[i]
                for c = 1, #kt do
                    local j = kt[c]
                    if b[j] <= EMPTY then
                        moves[move_idx] = move_pack(i, j, 0); move_idx = move_idx + 1
                    end
                end
            elseif p == K then
                local kg = king_targets[i]
                for c = 1, #kg do
                    local j = kg[c]
                    if b[j] <= EMPTY then
                        moves[move_idx] = move_pack(i, j, 0); move_idx = move_idx + 1
                    end
                end
            else
                -- Sliders: bishop (di 5..8), rook (di 1..4), queen (di 1..8).
                -- Castling (original semantics): when a ROOK at A1 slides E (or
                -- H1 slides W) and the square beyond the current j holds the
                -- king, emit the king's two-square move toward the rook:
                --   rook at A1: king at j+E -> j+W  (queenside)
                --   rook at H1: king at j+W -> j+E  (kingside)
                local sd = slider_dirs_by_piece[p]
                for s = 1, #sd do
                    local di = sd[s]
                    local ray = ray_squares[i][di]
                    local castling = p == R and (di == 2 or di == 4) -- E or W
                    local c = 1
                    while true do
                        local j = ray[c]
                        if j == 0 then break end
                        local q = b[j]
                        if q == EMPTY then
                            moves[move_idx] = move_pack(i, j, 0); move_idx = move_idx + 1
                        elseif q < 0 then
                            moves[move_idx] = move_pack(i, j, 0); move_idx = move_idx + 1
                            break
                        else
                            -- own piece blocks the ray, but if it's the king and
                            -- the rook has castling rights, emit the castling move
                            if castling then
                                if i == A1 and q == K and wc1 then
                                    moves[move_idx] = move_pack(j, j - 2, 0); move_idx = move_idx + 1
                                elseif i == H1 and q == K and wc2 then
                                    moves[move_idx] = move_pack(j, j + 2, 0); move_idx = move_idx + 1
                                end
                            end
                            break
                        end
                        c = c + 1
                    end
                end
            end
        end
    end
    return move_idx - 1 -- end index (count of moves written into `out`)
end

-------------------------------------------------------------------------------
-- Legality: the engine is a *chess* engine, so we enforce real chess rules.
-- A move is legal only if it does not leave the side-to-move's own king in
-- check, and captures of a protected enemy king are rejected (a king may
-- only be captured when the game has already been decided by checkmate).
-- genMoves() stays pseudo-legal for backward compatibility; legal_moves()
-- filters it. Search and public move validation use legal_moves().
-------------------------------------------------------------------------------

-- Is square `i` attacked by any opponent (lowercase) piece?
-- `i` is 0-indexed as in genMoves. Works on the integer array `_b`.
-- `b` is the board array; if nil it is fetched lazily (used by public paths).
function Position:attacked(i, b)
    b = b or self:ensure_arr()

    -- King attacks (opponent kings)
    local kg = king_targets[i]
    for c = 1, #kg do
        if b[kg[c]] == -K then return true end
    end

    -- Knight attacks
    local kt = knight_targets[i]
    for c = 1, #kt do
        if b[kt[c]] == -KN then return true end
    end

    -- Pawn attacks: an enemy pawn attacks square i along one diagonal. The
    -- engine rotates the board after every move, so the enemy pawn's "forward"
    -- can point toward index 0 (white frame) or index 119 (black frame).
    -- Checking both diagonals is safe: in a legal position an enemy pawn can
    -- only be on one diagonal from i, and the other can't be occupied by a
    -- pawn (it would be behind the pawn).
    local pc = pawn_caps[i]
    for c = 1, #pc do
        if b[pc[c]] == -P then return true end
    end

    -- Sliding pieces (rook, bishop, queen): walk the 8 precomputed rays.
    -- Rook rays (di 1..4) attack with -R/-Q; bishop rays (di 5..8) with -B/-Q.
    for di = 1, 4 do
        local ray = ray_squares[i][di]
        local c = 1
        while true do
            local sq = ray[c]
            if sq == 0 then break end
            local q = b[sq]
            if q == -R or q == -Q then return true end
            if q ~= EMPTY then break end
            c = c + 1
        end
    end
    for di = 5, 8 do
        local ray = ray_squares[i][di]
        local c = 1
        while true do
            local sq = ray[c]
            if sq == 0 then break end
            local q = b[sq]
            if q == -B or q == -Q then return true end
            if q ~= EMPTY then break end
            c = c + 1
        end
    end

    return false
end

-- Is the side to move in check? (own king is code K)
function Position:in_check()
    local king = self:king_index()
    if king then
        return self:attacked(king, self._b)
    end
    return false
end

-- Find the index of the side-to-move's king, or nil. Cached on the position
-- (`_king`) because the king's square only changes on a king move and positions
-- are immutable (is_legal's in-place board mutations always undo before return).
function Position:king_index()
    local k = self._king
    if not k then
        local b = self:ensure_arr()
        for i = 1, 120 do
            if b[i] == K then
                k = i
                self._king = i
                return i
            end
        end
    end
    return k
end

-- Find the index of the enemy king (code -K), or nil. Cached on the position
-- (`_eking`) for the same reason as `_king`. Only used to thread the child's
-- king indices through move()/rotate(); public positions scan on first use.
function Position:eking_index()
    local k = self._eking
    if not k then
        local b = self:ensure_arr()
        for i = 1, 120 do
            if b[i] == -K then
                k = i
                self._eking = i
                return i
            end
        end
    end
    return k
end

-- Squares that could affect the safety of the king at `king`: the 8 adjacent
-- squares plus all squares along the 8 rays from the king up to (and including)
-- the first occupied square. A non-king move only changes the king's attack
-- status if it touches one of these squares (or is en passant).
-- Returns `sens` (a generation-tagged table, truthy) and `gen` (the generation),
-- or nil if the king is currently attacked (no short-circuit is safe). Instead
-- of clearing the reusable table every call, we bump a generation counter and
-- store it per square; `is_legal` checks `sens[sq] == gen`.
local sens_tmp = {}
local sens_gen = 0
function Position:king_sensitive(king, b)
    b = b or self:ensure_arr()
    sens_gen = sens_gen + 1
    local g = sens_gen
    -- Adjacent squares.
    local kg = king_targets[king]
    for c = 1, #kg do sens_tmp[kg[c]] = g end
    -- Rays from the king.
    for di = 1, 8 do
        local ray = ray_squares[king][di]
        for c = 1, #ray do
            local sq = ray[c]
            sens_tmp[sq] = g
            if b[sq] ~= EMPTY then break end -- stop at first piece
        end
    end
    -- If the king is currently attacked, fall back to no short-circuit.
    if self:attacked(king, b) then return nil end
    return sens_tmp, g
end

-- Is the given pseudo-legal move legal? Applies the move in place on the
-- integer array, tests the own king, then undoes it.
-- `king` (optional) is the precomputed index of the own king.
-- `sens` (optional) is the king-sensitive square table from king_sensitive(),
-- `sens_g` its generation tag, or nil. When sens ~= nil and the move does not
-- touch a sensitive square, the king's safety is unchanged, so we can skip the
-- attacked() re-check.
function Position:is_legal(move, king, sens, b, sens_g)
    local i, j = move_from(move), move_to(move)
    b = b or self:ensure_arr()
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
        if sens then
            -- Short-circuit: if this move doesn't touch a sensitive square and
            -- isn't en passant, the king's safety is unchanged. `sens` being
            -- non-nil means the king is currently NOT attacked, so the move is
            -- legal.
            if i ~= king and sens[i] ~= sens_g and sens[j] ~= sens_g then
                local is_ep = p == P and ((j - i) == N + W or (j - i) == N + E) and q == EMPTY
                if not is_ep or sens[j + S] ~= sens_g then
                    return true
                end
            end
        end
        b[i] = EMPTY
        b[j] = p
        local ep_undo = false
        if p == P and ((j - i) == N + W or (j - i) == N + E) and q == EMPTY then
            -- en passant: capture the pawn behind the destination
            b[j + S] = EMPTY
            ep_undo = true
        end
        local legal = not self:attacked(king, b)
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
        if self:attacked(between, b) then
            legal = false
        else
            legal = not self:attacked(j, b)
        end
        -- undo
        b[i] = K
        b[between] = EMPTY
        b[j] = q
        return legal
    end

    b[i] = EMPTY
    b[j] = K
    local legal = not self:attacked(j, b)
    b[i] = K
    b[j] = q
    return legal
end

-- All legal moves (filtered from pseudo-legal genMoves).
function Position:legal_moves()
    local pseudo = {}
    local pe = self:genMoves(pseudo, 1)
    local legal = {}
    local n = 0
    local king = self:king_index()
    local b = self._b
    for k = 1, pe do
        local m = pseudo[k]
        if self:is_legal(m, king, nil, b) then
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

function Position:rotate(pooled)
    -- One pass over the integer array: reverse (k -> 119-k) and negate the
    -- piece codes (case swap). Padding codes are untouched.
    -- `pooled` (search null-move) reuses a pooled Position + board.
    local b = self:ensure_arr()
    local child, nb
    if pooled then
        child, nb = pool_alloc()
    else
        nb = {}
        child = nil
    end
    for k = 1, 120 do
        local v = b[121 - k]
        if v < 0 then
            nb[k] = -v
        elseif v > 6 then
            nb[k] = v
        else
            nb[k] = -v
        end
    end
    -- Thread king indices: after rotation, own king = mirror of parent's enemy
    -- king; enemy king = mirror of parent's own king. If either king is absent
    -- (e.g. a test position with only one king), fall back to the lazy scan.
    local ek = self._eking or self:eking_index()
    local ok = self._king or self:king_index()
    local nk, nek = nil, nil
    if ok and ek then nk = 121 - ek end
    if ek and ok then nek = 121 - ok end
    if pooled then
        child._b = nb
        child.score = -self.score
        child.wc = self.bc
        child.bc = self.wc
        child.ep = 121 - self.ep
        child.kp = 121 - self.kp
        child._king = nk
        child._eking = nek
        return child
    end
    return Position.from_array(nb, -self.score, self.bc, self.wc, 121 - self.ep, 121 - self.kp,
        nk, nek)
end

function Position:move(move, val, pooled)
    local i, j
    if type(move) == 'table' then
        i, j = move[1], move[2] -- public path: parsed UCI tuple
        val = nil
    else
        i, j = move_from(move), move_to(move) -- internal: packed int
    end
    local b = self:ensure_arr()
    local p = b[i]
    local q = b[j]

    local score = self.score + (val or self:value(move, b))
    local wc, bc, ep, kp = self.wc, self.bc, 0, 0

    if i == A1 then wc = { false, wc[2] } end
    if i == H1 then wc = { wc[1], false } end
    if j == A8 then bc = { bc[1], false } end
    if j == H8 then bc = { false, bc[2] } end

    if p == K then
        wc = { false, false }
        if math_abs(j - i) == 2 then
            kp = math_floor((i + j) / 2)
        end
    end

    if p == P and j - i == 2 * N then
        ep = i + N
    end

    -- Build the rotated board in a single pass (no copy-then-rotate). The
    -- moved-to square (j) becomes 119-j in the new frame (negated piece code =
    -- opposite color); the moved-from square (i) becomes 119-i and is emptied.
    -- Castling: the rook origin (A1/H1) is emptied and the rook lands on
    -- 119-kp. Promotion: the moved pawn becomes a negated queen. En passant:
    -- the captured pawn at j+S is emptied (valid only when j was empty).
    -- The common case (plain piece move, no castling/promotion) stays a tight
    -- 2-branch loop; rare special cases take a slower branch.
    -- `pooled` (search path) reuses a pooled Position + board; otherwise a
    -- fresh object + table is allocated (public API / tests).
    local child, nb
    if pooled then
        child, nb = pool_alloc()
    else
        nb = {}
        child = nil
    end
    local r = 121 - j
    local s = 121 - i
    if p == K and math_abs(j - i) == 2 then
        -- Castling: rook origin and rook destination are extra edits. The
        -- rotated frame negates colors, so the rook lands as -R (enemy).
        local rook_from = j < i and A1 or H1
        for k = 1, 120 do
            if k == r then
                nb[k] = -p
            elseif k == s then
                nb[k] = EMPTY
            elseif k == 121 - rook_from then
                nb[k] = EMPTY
            elseif k == 121 - kp then
                nb[k] = -R
            else
                local v = b[121 - k]
                if v < 0 then
                    nb[k] = -v
                elseif v > 6 then
                    nb[k] = v
                else
                    nb[k] = -v
                end
            end
        end
    else
        local dest = A8 <= j and j <= H8 and -Q or -p -- promotion -> queen
        for k = 1, 120 do
            if k == r then
                nb[k] = dest
            elseif k == s then
                nb[k] = EMPTY
            else
                local v = b[121 - k]
                if v < 0 then
                    nb[k] = -v
                elseif v > 6 then
                    nb[k] = v
                else
                    nb[k] = -v
                end
            end
        end
        if p == P and ((j - i) == N + W or (j - i) == N + E) and q == EMPTY then
            nb[121 - (j + S)] = EMPTY -- en passant
        end
    end
    -- Thread king indices: child own king = mirror of parent's enemy king;
    -- child enemy king = mirror of parent's own king, or of the king's new
    -- square when the king itself moved. If either king is absent, fall back
    -- to the lazy scan.
    local ek = self._eking or self:eking_index()
    local ok = self._king or self:king_index()
    local nk, nek = nil, nil
    if ek then nk = 121 - ek end
    if ok then nek = 121 - (p == K and j or ok) end
    if pooled then
        -- Reuse the pooled object: set the new frame fields on it.
        child._b = nb
        child.score = -score
        child.wc = bc
        child.bc = wc
        child.ep = 121 - ep
        child.kp = 121 - kp
        child._king = nk
        child._eking = nek
        return child
    end
    return Position.from_array(nb, -score, bc, wc, 121 - ep, 121 - kp, nk, nek)
end

function Position:value(move, b)
    local i, j
    if type(move) == 'table' then
        i, j = move[1], move[2] -- public path: parsed UCI tuple
    else
        i, j = move_from(move), move_to(move) -- internal: packed int
    end
    b = b or self:ensure_arr()
    local p = b[i]
    local q = b[j]

    -- Squares i/j are 1-based; pst tables are keyed 1-based (pst[piece][sq]).
    local pp = pst[p]
    local score = pp[j] - pp[i]
    if q < 0 then
        score = score + pst[-q][j] -- captured piece's PST value
    end

    local kp = self.kp
    if j - kp < 2 and kp - j < 2 then
        score = score + pst[K][j]
    end

    if p == K and (j - i == 2 or i - j == 2) then
        score = score + pst[R][math_floor((i + j) / 2)]
        score = score - pst[R][j < i and A1 or H1]
    end

    if p == P then
        if A8 <= j and j <= H8 then
            score = score + pst[Q][j] - pst[P][j]
        end
        if j == self.ep then
            score = score + pst[P][j + S]
        end
    end
    return score
end

-- Fixed-size transposition table as five parallel arrays (no per-slot table
-- chase, no temp table at the store site). Probing uses key % TT_SIZE and
-- verifies ttK[s] == key (full 32-bit key), so hash collisions only cause a
-- missed entry, never a wrong result.
local ttK = {}
local ttD = {}
local ttS = {}
local ttG = {}
local ttM = {}

-- Pre-size the five parallel arrays at module load. Lua tables grow
-- incrementally; without this the first search pays several rehashes while
-- filling up to TT_SIZE integer keys *during the timed region*. Filling with
-- sentinels (ttK = -1) allocates the array part once; a probe verifies
-- ttK[s] == key, so the sentinel can never be a false match (keys are >= 0).
for s = 1, TT_SIZE do
    ttK[s] = -1
    ttD[s] = 0
    ttS[s] = 0
    ttG[s] = 0
    ttM[s] = 0
end

local function tp_set(key, depth, score, gamma, move)
    local s = key % TT_SIZE + 1
    ttK[s] = key
    ttD[s] = depth
    ttS[s] = score
    ttG[s] = gamma
    ttM[s] = move
end

-- Probe the TT. Returns (score, depth, move, slot) when an entry exists, else
-- nil. The slot is `key % TT_SIZE + 1` (already computed here) so the caller's
-- bound-check can reuse it instead of recomputing the modulo.
local function tp_get(key)
    local s = key % TT_SIZE + 1
    if ttK[s] == key then
        return ttS[s], ttD[s], ttM[s], s
    end
    return nil
end

-------------------------------------------------------------------------------
-- Search logic
-------------------------------------------------------------------------------

local nodes = 0
local yield_left = YIELD_QUANTUM -- countdown for the periodic coroutine yield

-- Hoist hot Position methods to upvalues: each `pos:method()` is a table read
-- that misses into __index (a metamethod event + function lookup). Binding
-- once and calling as plain functions removes that indirection from the
-- per-node hot path (~10 dispatches per node).
local m_genMoves = Position.genMoves
local m_king_index = Position.king_index
local m_king_sensitive = Position.king_sensitive
local m_is_legal = Position.is_legal
local m_in_check = Position.in_check
local m_key = Position.key
local m_rotate = Position.rotate
local m_value = Position.value
local m_move = Position.move

-------------------------------------------------------------------------------
-- Pooled move buffer + count-driven sort (search hot path)
--
-- genMoves writes packed moves into a caller-provided array and returns the
-- end index; bound() filters/sorts in place on a module-level reusable buffer.
-- No `#` (LuaJ's rawlen is a binary search), no table.sort null-scan, no tail
-- clear -- the explicit count says exactly how many entries are live. Entries
-- beyond the count are stale but never read. This removes the per-node list
-- table allocation that the earlier scratch-pooling attempt could not (it
-- relied on `#`, whose bookkeeping overhead made it slower).
--
-- The comparator is `move_greater` below (value desc via packed integer,
-- tie-break i desc / j asc). Written as a plain heap sort with an explicit
-- count so we never need `#` or a nil boundary.

-- Per-depth move buffers: each bound() frame needs its own buffer because the
-- recursion overwrites shared storage while the outer frame still iterates its
-- sorted moves. Buffers are indexed by search depth (bounded ~10-20 plies),
-- so each frame reads/writes its own region; no clear needed (explicit count).
local move_stack = {}
local ply = 0 -- current recursion depth (incremented per bound() entry)

local function move_greater(a, b)
    if a ~= b then
        if a > b then return true end
        if a < b then return false end
        local ai, aj = move_from(a), move_to(a)
        local bi, bj = move_from(b), move_to(b)
        if ai ~= bi then
            return ai > bi
        else
            return aj < bj
        end
    end
    return false
end

-- In-place heap sort of buf[1..n] descending by `move_greater`.
-- Classic max-heap + extract-to-end produces ASCENDING; for descending we build
-- a MIN-heap (smallest at root) and extract to the end, so the largest lands
-- first. The comparator is inverted for the heap property.
local function move_sort(buf, n)
    -- build min-heap (root is the smallest)
    for start = math_floor(n / 2), 1, -1 do
        local root = start
        while root * 2 <= n do
            local child = root * 2
            if child < n and move_greater(buf[child], buf[child + 1]) then
                child = child + 1
            end
            if move_greater(buf[root], buf[child]) then
                buf[root], buf[child] = buf[child], buf[root]
                root = child
            else
                break
            end
        end
    end
    -- extract min to the end -> descending order
    for endpos = n, 2, -1 do
        buf[1], buf[endpos] = buf[endpos], buf[1]
        local root = 1
        local m = endpos - 1
        while root * 2 <= m do
            local child = root * 2
            if child < m and move_greater(buf[child], buf[child + 1]) then
                child = child + 1
            end
            if move_greater(buf[root], buf[child]) then
                buf[root], buf[child] = buf[child], buf[root]
                root = child
            else
                break
            end
        end
    end
end

local function bound(pos, gamma, depth)
    nodes = nodes + 1
    -- Countdown-based yield: one decrement + compare per node (vs a modulo),
    -- and a coroutine switch only every YIELD_QUANTUM nodes.
    if YIELD_ENABLED then
        yield_left = yield_left - 1
        if yield_left == 0 then
            yield_left = YIELD_QUANTUM
            coroutine.yield()
        end
    end

    if math_abs(pos.score) >= MATE_VALUE then
        return pos.score
    end

    -- Look up the transposition table BEFORE move generation. A usable entry
    -- (same depth, bound satisfied) lets us return immediately without paying
    -- for genMoves + the legality filter. Mate/stalemate is safe: a position
    -- with no legal moves never stores a TT entry (we only store after a legal
    -- move is found), and the terminal-score check above catches
    -- already-decided positions.
    local key = m_key(pos)
    local es, ed, _, ed_slot = tp_get(key)
    local had_entry = es ~= nil
    if had_entry and ed >= depth and (
            es < ttG[ed_slot] and es < gamma or
                    es >= ttG[ed_slot] and es >= gamma) then
        return es
    end

    -- Generate pseudo-legal moves and filter out those that leave our own king
    -- in check. If no legal move exists the position is checkmate or stalemate.
    -- genMoves writes packed moves into this frame's per-ply buffer; we filter
    -- in place (nlegal <= k, so compaction never overwrites an unread entry).
    ply = ply + 1
    local buf = move_stack[ply]
    if not buf then
        buf = {}
        move_stack[ply] = buf
    end
    local pe = m_genMoves(pos, buf, 1)
    local nlegal = 0
    local king = m_king_index(pos)
    local b = pos._b
    local sens, sens_g = m_king_sensitive(pos, king, b)
    for k = 1, pe do
        local move = buf[k]
        if m_is_legal(pos, move, king, sens, b, sens_g) then
            nlegal = nlegal + 1
            buf[nlegal] = move
        end
    end
    if nlegal == 0 then
        ply = ply - 1
        if m_in_check(pos) then
            return -MATE_VALUE -- checkmate: side to move loses
        else
            return 0 -- stalemate
        end
    end

    local null_child = m_rotate(pos, true) -- pooled: no alloc in the hot path
    local nullscore = depth > 0 and -bound(null_child, 1 - gamma, depth - 3) or pos.score
    pool_free_pos(null_child) -- the null-move child is dead after this node
    if nullscore >= gamma then
        ply = ply - 1
        return nullscore
    end

    local best, bmove = -3 * MATE_VALUE, nil

    -- Cache calculated move values so the sort doesn't repeatedly call `pos:value()` $O(N \log N)$ times
    for k = 1, nlegal do
        buf[k] = move_set_val(buf[k], m_value(pos, buf[k], b))
    end

    -- At depth <= 0 the loop below breaks at the first move_val < 150 (the
    -- tail is never searched), so filter to the >= 150 subset BEFORE sorting:
    -- the searched set and order are unchanged, but the heap sort only sees the
    -- kept subset (leaves are a large fraction of nodes). Compaction is in
    -- place (nlegal <= k, never overwrites an unread entry); the kept count is
    -- exact so no `#` or tail-clear is needed.
    local sort_n = nlegal
    if depth <= 0 then
        local keep = 0
        for k = 1, nlegal do
            if move_val(buf[k]) >= 150 then
                keep = keep + 1
                buf[keep] = buf[k]
            end
        end
        sort_n = keep
    end

    move_sort(buf, sort_n)

    for k = 1, sort_n do
        local move = buf[k]
        local mv = move_val(move)
        local child = m_move(pos, move, mv, true) -- pooled
        local score = -bound(child, 1 - gamma, depth - 1)
        pool_free_pos(child) -- the child is dead after its subtree returns
        if score > best then
            best = score
            bmove = move
        end
        if score >= gamma then
            break
        end
    end

    if depth <= 0 and best < nullscore then
        ply = ply - 1
        return nullscore
    end

    if not had_entry or depth >= ed and best >= gamma then
        tp_set(key, depth, best, gamma, bmove)
    end
    ply = ply - 1
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

        if VERBOSE then
            print(string_format("Searched %d nodes. Depth %d. Score %d(%d/%d)", nodes, depth, score, lower, upper))
        end

        if nodes >= maxn or math_abs(score) >= MATE_VALUE then
            break
        end
    end

    local _, _, rootmove = tp_get(m_key(pos))
    if rootmove ~= nil then
        return rootmove, score
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
    -- `i` is a 0-based public square (A1=91). Use the 0-based A1 constant.
    local rank, fil = math_floor((i - 91) / 10), (i - 91) % 10
    return string.char(fil + string_byte('a')) .. tostring(-rank + 1)
end

--//RPD interface:

local sunfish = {}

sunfish.MATE_VALUE = MATE_VALUE

-- Tunable yield behavior for the search coroutine (see the YIELD_QUANTUM
-- comment near the top of the file). Pass enable=false to disable yields
-- entirely (throughput ceiling; only safe where the caller never polls).
function sunfish.set_yield(quantum, enable)
    if quantum then YIELD_QUANTUM = quantum end
    if enable ~= nil then YIELD_ENABLED = enable end
    yield_left = YIELD_QUANTUM -- re-arm so the next search uses the new quantum
end

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
    if not (move[1] and move[2]) then
        return false
    end
    -- Validate ONE user move instead of building the whole legal_moves() list:
    -- generate pseudo-legal moves, find the matching {i, j}, and run is_legal on
    -- only that move. This keeps sunfish.move snappy under LuaJ (legal_moves
    -- filters every pseudo-move through is_legal + attacked()).
    local pseudo = {}
    local pe = game:genMoves(pseudo, 1)
    local b = game:ensure_arr()
    local king = game:king_index()
    local sens, sens_g = game:king_sensitive(king, b)
    for k = 1, pe do
        local m = pseudo[k]
        if move_from(m) == move[1] and move_to(m) == move[2] then
            if game:is_legal(m, king, sens, b, sens_g) then
                local ng = game:move(move)
                ng:ensure_board()
                return ng
            end
            return false
        end
    end
    return false
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

    return game, render(119 - move_from(move)) .. render(119 - move_to(move)), score
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
    -- parse() returns 1-based (internal convention); public API is 0-based
    return parse(string_sub(move, 1, 2)) - 1
end

return sunfish
