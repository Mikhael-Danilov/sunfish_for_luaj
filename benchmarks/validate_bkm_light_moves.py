#!/usr/bin/env python3
"""Validate bkm_light.lua's best_move against the oracle tables.

For a random sample of legal states:
  * every returned move must be legal (kings not adjacent, not in check, no
    overlap, piece not hanging unnecessarily)
  * strong to move, WIN: the move must not regress DTM (a winning move keeps
    DTM strictly decreasing; since the light mover is heuristic it may pick a
    non-optimal-but-still-winning move, so we require ndtm <= odtm - 1 and
    nst == WIN)
  * strong to move, DRAW: move must be legal and not lose (nst != WIN for
    strong from a draw is impossible since strong can only hold draw)
  * weak to move, WIN: move must keep WIN (delay mate)
  * weak to move, DRAW: move must keep DRAW

Usage:
  python3 benchmarks/validate_bkm_light_moves.py [lua] [n] [seed] [oracle_dir]
"""

import os
import random
import subprocess
import sys

import chess

LUA = sys.argv[1] if len(sys.argv) > 1 else "luajit"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else 20260813
ORACLE_DIR = sys.argv[4] if len(sys.argv) > 4 else "/tmp/bkm_oracle"

LUA_PROBE = r"""
local bkm = require("bkm_light")
local piece = os.getenv("BKM_PIECE")
local n = tonumber(os.getenv("BKM_N"))
local seed = tonumber(os.getenv("BKM_SEED"))
local rng = { x = seed }
function rng:next(m)
  self.x = (self.x * 1664525 + 1013904223) % 4294967296
  return math.floor(self.x / 65536) % m
end
local adj = {}
for a = 0, 63 do
  adj[a] = {}
  local af, ar = a % 8, math.floor(a / 8)
  for b = 0, 63 do
    local bf, br = b % 8, math.floor(b / 8)
    if math.max(math.abs(af - bf), math.abs(ar - br)) <= 1 then
      adj[a][b] = true
    end
  end
end
local seen = {}
local out = {}
local total = 0
local tries = 0
local function attack_bk(wk, pc, bk)
  if pc == bk then return false end
  local pf, pr = pc % 8, math.floor(pc / 8)
  local tf, tr = bk % 8, math.floor(bk / 8)
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
    if r * 8 + f == wk then return false end
    f = f + sf
    r = r + sr
  end
  return true
end
local function sample_state()
  for _ = 1, 500 do
    local wk = rng:next(64)
    local bk = rng:next(64)
    if adj[wk][bk] then return nil end
    local pc = rng:next(64)
    if pc == wk or pc == bk then return nil end
    local stm = rng:next(2)
    if stm == 0 and attack_bk(wk, pc, bk) then return nil end
    local key = wk * 8192 + pc * 128 + bk * 2 + stm
    if not seen[key] then
      seen[key] = true
      return wk, pc, bk, stm
    end
  end
  return nil
end
while total < n and tries < n * 200 do
  tries = tries + 1
  local wk, pc, bk, stm = sample_state()
  if wk then
    total = total + 1
    local mv = bkm.best_move({ wk = wk, pc = pc, bk = bk, stm = stm }, piece)
    if mv then
      out[#out + 1] = string.format("%d,%d,%d,%d,%d,%d,%d", wk, pc, bk, stm, mv.from, mv.to, mv.capture and 1 or 0)
    else
      out[#out + 1] = string.format("%d,%d,%d,%d,-1,-1,0", wk, pc, bk, stm)
    end
  end
end
io.write(table.concat(out, "\n"))
"""


def sq(s):
    return chess.SQUARE_NAMES[s]


def load_oracle(piece):
    with open(f"{ORACLE_DIR}/oracle_{piece}.bin", "rb") as f:
        return f.read()


def oracle_status_dtm(data, wk, pc, bk, stm):
    idx = wk + pc * 64 + bk * 4096 + stm * 262144
    return data[2 * idx], data[2 * idx + 1]


def make_board(wk, pc, bk, piece, stm):
    board = chess.Board.empty()
    board.set_piece_at(wk, chess.Piece(chess.KING, chess.WHITE))
    board.set_piece_at(
        pc,
        chess.Piece(chess.QUEEN if piece == "Q" else chess.ROOK, chess.WHITE),
    )
    board.set_piece_at(bk, chess.Piece(chess.KING, chess.BLACK))
    board.turn = chess.WHITE if stm == 0 else chess.BLACK
    return board


def main():
    for piece in ("R", "Q"):
        data = load_oracle(piece)
        env = dict(
            os.environ,
            BKM_PIECE=piece,
            BKM_N=str(N),
            BKM_SEED=str(SEED + (0 if piece == "R" else 1)),
        )
        proc = subprocess.run(
            [LUA, "-e", LUA_PROBE], capture_output=True, text=True, env=env
        )
        if proc.returncode != 0:
            print(f"[{piece}] lua probe failed: {proc.stderr}")
            sys.exit(1)
        mism = 0
        checked = 0
        illegal = 0
        for line in proc.stdout.strip().splitlines():
            wk, pc, bk, stm, f, t, cap = map(int, line.split(","))
            ost, odtm = oracle_status_dtm(data, wk, pc, bk, stm)
            if ost == 3:
                continue  # skip states the oracle deems invalid
            checked += 1
            if f == -1:
                # nil move: legal for terminal states (mate DTM 0, or stalemate)
                if not (ost == 1 and odtm == 0) and not (ost == 2 and stm == 1):
                    print(
                        f"  {piece} wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm}: "
                        f"nil move for non-terminal state (oracle {ost}/{odtm})"
                    )
                    mism += 1
                continue
            board = make_board(wk, pc, bk, piece, stm)
            mv = chess.Move(f, t)
            if mv not in board.legal_moves:
                print(
                    f"  {piece} wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm}: "
                    f"ILLEGAL move {sq(f)}->{sq(t)}"
                )
                illegal += 1
                mism += 1
                continue
            b2 = board.copy()
            b2.push(mv)
            nwk, npc, nbk = wk, pc, bk
            if f == wk:
                nwk = t
            elif f == pc:
                npc = t
            elif f == bk:
                nbk = t
            # weak-side capture of the strong piece is a legal terminal draw
            if f == bk and t == pc:
                continue
            if nwk == npc or nwk == nbk or npc == nbk:
                print(
                    f"  {piece} OVERLAP wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm} "
                    f"move {sq(f)}->{sq(t)} piece={ 'K' if f==wk or f==bk else piece }"
                )
                mism += 1
                continue
            nstm = 1 - stm
            nst, ndtm = oracle_status_dtm(data, nwk, npc, nbk, nstm)
            if nst == 3:
                print(f"  {piece} result invalid after {sq(f)}->{sq(t)}")
                mism += 1
                continue
            if stm == 0:
                if ost == 1:
                    # winning: must stay a win, DTM must not regress
                    if nst != 1:
                        print(
                            f"  {piece} wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm}: "
                            f"WIN state, strong move {sq(f)}->{sq(t)} -> oracle {nst}/{ndtm} (not WIN)"
                        )
                        mism += 1
                    elif ndtm > odtm - 1:
                        print(
                            f"  {piece} wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm}: "
                            f"WIN state, strong move {sq(f)}->{sq(t)} -> DTM {ndtm} (regressed from {odtm})"
                        )
                        mism += 1
                else:
                    # draw: strong must not hang the piece (a capture would be
                    # impossible to be forced; the oracle treats it as terminal draw)
                    if nst == 1:
                        print(
                            f"  {piece} wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm}: "
                            f"DRAW state, strong move {sq(f)}->{sq(t)} -> WIN (should be DRAW)"
                        )
                        mism += 1
            else:
                # weak to move
                if ost == 2:
                    if nst != 2 and not cap:
                        print(
                            f"  {piece} wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm}: "
                            f"weak DRAW move {sq(f)}->{sq(t)} -> oracle {nst}/{ndtm}, expected DRAW"
                        )
                        mism += 1
                else:
                    # WIN: weak must delay (ndtm == odtm - 1), or capture (draw)
                    if cap:
                        continue
                    if nst != 1 or ndtm != odtm - 1:
                        print(
                            f"  {piece} wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm}: "
                            f"weak WIN move {sq(f)}->{sq(t)} -> oracle {nst}/{ndtm}, expected WIN/{odtm - 1}"
                        )
                        mism += 1
        print(f"[{piece}] checked {checked} states, {illegal} illegal, {mism} total mismatches")
        if mism:
            any_mism = True


if __name__ == "__main__":
    any_mism = False
    main()
    sys.exit(1 if any_mism else 0)
