-- bkm.lua
--
-- Canonical algorithmic KRK and KQK solver.
--
-- Implements an exact retrograde solver for King+Rook vs King and
-- King+Queen vs King, with Bratko-Kopec-Michie-style distance tie-breaks.
--
-- Square encoding:
--   0..63, a1 = 0, b1 = 1, ..., h8 = 63
--
-- Side to move:
--   0 = strong side to move  (side with rook/queen)
--   1 = weak side to move    (lone king)
--
-- Usage:
--   local bkm = require("bkm")
--   local krk = bkm.solver("R")
--   local mv = krk:best_move {
--     wk  = bkm.square("b6"),
--     pc  = bkm.square("h1"),
--     bk  = bkm.square("a8"),
--     stm = 0,
--   }
--   print(bkm.alg(mv.from), bkm.alg(mv.to))  --> h1 h8

local bkm = {}

---------------------------------------------------------------
-- Squares / coordinates
---------------------------------------------------------------

function bkm.square(s)
  if type(s) == "number" then return s end
  local f = s:sub(1, 1):lower():byte() - ("a"):byte()
  local r = tonumber(s:sub(2, 2)) - 1
  if f < 0 or f > 7 or r < 0 or r > 7 then
    error("invalid square: " .. tostring(s))
  end
  return r * 8 + f
end

function bkm.alg(sq)
  if not sq then return "?" end
  return string.char(("a"):byte() + (sq % 8)) .. tostring(math.floor(sq / 8) + 1)
end

local function file(sq)
  return sq % 8
end

local function rank(sq)
  return math.floor(sq / 8)
end

---------------------------------------------------------------
-- Precomputed king attacks, Chebyshev distances, edge distances
---------------------------------------------------------------

local king_attacks = {}
local cheb_dist = {}
local edge_dist = {}

for a = 0, 63 do
  local af, ar = file(a), rank(a)

  edge_dist[a + 1] = math.min(af, ar, 7 - af, 7 - ar)

  for b = 0, 63 do
    local bf, br = file(b), rank(b)
    local d = math.max(math.abs(af - bf), math.abs(ar - br))
    cheb_dist[a * 64 + b + 1] = d
  end
end

local function cheb(a, b)
  return cheb_dist[a * 64 + b + 1]
end

for s = 0, 63 do
  local f, r = file(s), rank(s)
  local t = {}
  for df = -1, 1 do
    for dr = -1, 1 do
      if df ~= 0 or dr ~= 0 then
        local nf, nr = f + df, r + dr
        if nf >= 0 and nf < 8 and nr >= 0 and nr < 8 then
          table.insert(t, nr * 8 + nf)
        end
      end
    end
  end
  king_attacks[s] = t
end

---------------------------------------------------------------
-- State encoding / decoding
---------------------------------------------------------------

-- 64 * 64 * 64 * 2 = 524288 states
local STATE_COUNT = 64 * 64 * 64 * 2

local function encode(wk, pc, bk, stm)
  return 1 + wk + pc * 64 + bk * 4096 + stm * 262144
end

local function decode(id)
  local x = id - 1
  local stm = math.floor(x / 262144)
  x = x % 262144
  local bk = math.floor(x / 4096)
  x = x % 4096
  local pc = math.floor(x / 64)
  local wk = x % 64
  return wk, pc, bk, stm
end

---------------------------------------------------------------
-- Solver factory
---------------------------------------------------------------

local function make_solver(piece)
  assert(piece == "R" or piece == "Q", "piece must be 'R' or 'Q'")

  local dirs
  if piece == "R" then
    dirs = {
      { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    }
  else
    dirs = {
      { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
      { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
    }
  end

  local UNKNOWN, WIN, DRAW, INVALID = 0, 1, 2, 3

  local status = {}
  local dtm = {}
  local info = {}

  for i = 1, STATE_COUNT do
    status[i] = UNKNOWN
    dtm[i] = 0
    info[i] = 0
  end

  -------------------------------------------------------------
  -- Piece attacks, with only one blocker: the strong king.
  -------------------------------------------------------------

  local function attacked_by_piece(pc, target, blocker)
    if pc == target then return false end

    local pf, pr = file(pc), rank(pc)
    local tf, tr = file(target), rank(target)
    local df, dr = tf - pf, tr - pr
    local adf, adr = math.abs(df), math.abs(dr)

    local ok
    if piece == "R" then
      ok = (df == 0 or dr == 0)
    else
      ok = (df == 0 or dr == 0 or adf == adr)
    end

    if not ok then return false end

    local sf = (df > 0 and 1) or (df < 0 and -1) or 0
    local sr = (dr > 0 and 1) or (dr < 0 and -1) or 0

    local f, r = pf + sf, pr + sr
    while f ~= tf or r ~= tr do
      local s = r * 8 + f
      if s == blocker then
        return false
      end
      f = f + sf
      r = r + sr
    end

    return true
  end

  -------------------------------------------------------------
  -- Weak king legal move count.
  -- Captures of the strong piece are counted as legal moves,
  -- but they lead to terminal draws outside the encoded graph.
  -------------------------------------------------------------

  local function weak_legal_count(wk, pc, bk)
    local n = 0

    for _, to in ipairs(king_attacks[bk]) do
      if to == pc then
        -- Capture is legal iff the captured piece is not protected
        -- by the strong king.
        if cheb(to, wk) > 1 then
          n = n + 1
        end
      elseif to ~= wk then
        if cheb(to, wk) > 1 and not attacked_by_piece(pc, to, wk) then
          n = n + 1
        end
      end
    end

    return n
  end

  -------------------------------------------------------------
  -- Win buckets for retrograde propagation.
  -------------------------------------------------------------

  local buckets = {}
  local maxq = -1

  local function enqueue_win(i, d)
    status[i] = WIN
    dtm[i] = d

    local b = buckets[d]
    if not b then
      b = {}
      buckets[d] = b
      if d > maxq then maxq = d end
    end

    table.insert(b, i)
  end

  -------------------------------------------------------------
  -- Initialize legality, terminal mates, and weak move counts.
  -------------------------------------------------------------

  for stm = 0, 1 do
    local base_stm = stm * 262144

    for bk = 0, 63 do
      local base_bk = bk * 4096

      for pc = 0, 63 do
        local base_pc = pc * 64

        for wk = 0, 63 do
          local idx = 1 + wk + base_pc + base_bk + base_stm

          if wk == pc or wk == bk or pc == bk or cheb(wk, bk) <= 1 then
            status[idx] = INVALID
          elseif stm == 0 and attacked_by_piece(pc, bk, wk) then
            -- If strong side is to move, weak king cannot already be in check.
            status[idx] = INVALID
          else
            if stm == 1 then
              local cnt = weak_legal_count(wk, pc, bk)

              if cnt == 0 then
                if attacked_by_piece(pc, bk, wk) then
                  -- Checkmate.
                  enqueue_win(idx, 0)
                end
                -- Else stalemate: leave UNKNOWN; finalized as DRAW later.
              else
                -- Pack:
                --   count  : high bits
                --   seen   : middle bits
                --   maxdtm : low bits
                info[idx] = cnt * 4096
              end
            end
          end
        end
      end
    end
  end

  -------------------------------------------------------------
  -- Predecessor update helpers.
  -------------------------------------------------------------

  local function try_strong_pred(p, d)
    if status[p] == UNKNOWN then
      enqueue_win(p, d + 1)
    end
  end

  local function try_weak_pred(p, d)
    if status[p] ~= UNKNOWN then return end

    local inf = info[p]
    local c = math.floor(inf / 4096)
    if c == 0 then return end

    local s = math.floor(inf / 256) % 16
    local m = inf % 256

    s = s + 1
    if d > m then m = d end

    if s == c then
      enqueue_win(p, m + 1)
    else
      info[p] = c * 4096 + s * 256 + m
    end
  end

  -------------------------------------------------------------
  -- Retrograde propagation of wins only.
  -- Unknown states remaining after this are draws.
  -------------------------------------------------------------

  local d = 0
  while d <= maxq do
    local q = buckets[d]

    if q then
      for _, sidx in ipairs(q) do
        local wk, pc, bk, stm = decode(sidx)

        if stm == 1 then
          -- Current state: weak to move.
          -- Previous move was by strong side: king move or piece move.

          -- Previous strong king moves.
          for _, prev_wk in ipairs(king_attacks[wk]) do
            if prev_wk ~= pc and prev_wk ~= bk and cheb(prev_wk, bk) > 1 then
              local p = encode(prev_wk, pc, bk, 0)
              if status[p] == UNKNOWN then
                try_strong_pred(p, d)
              end
            end
          end

          -- Previous strong piece moves.
          for _, dir in ipairs(dirs) do
            local df, dr = dir[1], dir[2]
            local f, r = file(pc) + df, rank(pc) + dr

            while f >= 0 and f < 8 and r >= 0 and r < 8 do
              local sq = r * 8 + f

              if sq == wk or sq == bk then
                break
              end

              local p = encode(wk, sq, bk, 0)
              if status[p] == UNKNOWN then
                try_strong_pred(p, d)
              end

              f = f + df
              r = r + dr
            end
          end
        else
          -- Current state: strong to move.
          -- Previous move was by weak king.

          for _, prev_bk in ipairs(king_attacks[bk]) do
            if prev_bk ~= wk and prev_bk ~= pc and cheb(prev_bk, wk) > 1 then
              local p = encode(wk, pc, prev_bk, 1)
              if status[p] == UNKNOWN then
                try_weak_pred(p, d)
              end
            end
          end
        end
      end
    end

    buckets[d] = nil
    d = d + 1
  end

  -------------------------------------------------------------
  -- Finalize draws.
  -------------------------------------------------------------

  for i = 1, STATE_COUNT do
    if status[i] == UNKNOWN then
      status[i] = DRAW
    end
  end

  -- No longer needed after build.
  info = nil

  -------------------------------------------------------------
  -- Move generation for best-move extraction.
  -------------------------------------------------------------

  local function strong_moves(wk, pc, bk)
    local moves = {}

    -- Strong king moves.
    for _, to in ipairs(king_attacks[wk]) do
      if to ~= pc and to ~= bk and cheb(to, bk) > 1 then
        table.insert(moves, {
          from = wk,
          to = to,
          piece = "K",
          state = encode(to, pc, bk, 1),
        })
      end
    end

    -- Strong piece moves.
    for _, dir in ipairs(dirs) do
      local df, dr = dir[1], dir[2]
      local f, r = file(pc) + df, rank(pc) + dr

      while f >= 0 and f < 8 and r >= 0 and r < 8 do
        local sq = r * 8 + f

        if sq == wk or sq == bk then
          break
        end

        table.insert(moves, {
          from = pc,
          to = sq,
          piece = piece,
          state = encode(wk, sq, bk, 1),
        })

        f = f + df
        r = r + dr
      end
    end

    return moves
  end

  local function weak_moves(wk, pc, bk)
    local moves = {}

    for _, to in ipairs(king_attacks[bk]) do
      if to == pc then
        if cheb(to, wk) > 1 then
          table.insert(moves, {
            from = bk,
            to = to,
            piece = "K",
            capture = true,
          })
        end
      elseif to ~= wk then
        if cheb(to, wk) > 1 and not attacked_by_piece(pc, to, wk) then
          table.insert(moves, {
            from = bk,
            to = to,
            piece = "K",
            state = encode(wk, pc, to, 0),
          })
        end
      end
    end

    return moves
  end

  -------------------------------------------------------------
  -- BKM-style heuristic tie-breaker.
  -- Lower is better for the strong side.
  -------------------------------------------------------------

  local function bkm_score(wk, pc, bk)
    local e = edge_dist[bk + 1]
    local kd = cheb(wk, bk)

    if kd > 0 then
      kd = kd - 1
    end

    local pd = cheb(pc, bk)

    return e * 128 + kd * 16 + pd
  end

  -------------------------------------------------------------
  -- Public solver object.
  -------------------------------------------------------------

  local solver = {
    piece = piece,
    status = status,
    dtm = dtm,

    UNKNOWN = UNKNOWN,
    WIN = WIN,
    DRAW = DRAW,
    INVALID = INVALID,

    STRONG = 0,
    WEAK = 1,

    encode = encode,
    decode = decode,
  }

  function solver:bkm_score(wk, pc, bk)
    return bkm_score(wk, pc, bk)
  end

  function solver:evaluate(wk, pc, bk, stm)
    local id = encode(wk, pc, bk, stm or 0)
    return status[id], dtm[id]
  end

  function solver:is_win(wk, pc, bk, stm)
    local id = encode(wk, pc, bk, stm or 0)
    return status[id] == WIN
  end

  function solver:dtm(wk, pc, bk, stm)
    local id = encode(wk, pc, bk, stm or 0)
    if status[id] == WIN then
      return dtm[id]
    end
    return nil
  end

  function solver:best_move(pos)
    local wk = pos.wk
    local pc = pos.pc
    local bk = pos.bk
    local stm = pos.stm or 0

    local id = encode(wk, pc, bk, stm)
    if status[id] == INVALID then
      return nil
    end

    if stm == 0 then
      -----------------------------------------------------------
      -- Strong side to move: choose winning move with minimal DTM.
      -----------------------------------------------------------

      local moves = strong_moves(wk, pc, bk)

      local best, best_d, best_score, best_key

      for _, m in ipairs(moves) do
        local cst = status[m.state]

        if cst == WIN then
          local cd = dtm[m.state]
          local cw, cp, cb = decode(m.state)
          local sc = bkm_score(cw, cp, cb)
          local key = m.from * 64 + m.to

          if not best
            or cd < best_d
            or (cd == best_d and sc < best_score)
            or (cd == best_d and sc == best_score and key < best_key)
          then
            best = m
            best_d = cd
            best_score = sc
            best_key = key
          end
        end
      end

      if best then
        return best
      end

      -- No forced win: prefer a drawing move.
      for _, m in ipairs(moves) do
        if status[m.state] == DRAW then
          return m
        end
      end

      return moves[1]
    else
      -----------------------------------------------------------
      -- Weak side to move:
      --   if draw exists, choose it;
      --   otherwise delay mate as long as possible.
      -----------------------------------------------------------

      local moves = weak_moves(wk, pc, bk)

      if status[id] == DRAW then
        for _, m in ipairs(moves) do
          if m.capture then
            return m
          end
          if m.state and status[m.state] == DRAW then
            return m
          end
        end
      end

      local best, best_d, best_score, best_key

      for _, m in ipairs(moves) do
        if m.capture then
          -- Immediate capture of the rook/queen is a draw.
          return m
        end

        local cst = status[m.state]

        if cst == DRAW then
          return m
        elseif cst == WIN then
          local cd = dtm[m.state]
          local cw, cp, cb = decode(m.state)
          local sc = bkm_score(cw, cp, cb)
          local key = m.from * 64 + m.to

          if not best
            or cd > best_d
            or (cd == best_d and sc > best_score)
            or (cd == best_d and sc == best_score and key < best_key)
          then
            best = m
            best_d = cd
            best_score = sc
            best_key = key
          end
        end
      end

      return best or moves[1]
    end
  end

  return solver
end

---------------------------------------------------------------
-- Cached solver accessors
---------------------------------------------------------------

local cache = {}

function bkm.solver(piece)
  piece = piece:upper()
  if not cache[piece] then
    cache[piece] = make_solver(piece)
  end
  return cache[piece]
end

return bkm
