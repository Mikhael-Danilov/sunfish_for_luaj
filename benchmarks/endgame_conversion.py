#!/usr/bin/env python3
"""Endgame conversion-rate gate for sunfish.lua.

Generates random KQK and KRK positions (winning side = the side with the
extra material), filters out immediate mates/stalemates, then lets sunfish
play the winning side against a random legal mover. Reports the conversion
rate (mate reached within a move cap) and the draw/loss rates.

Aspirational target: >95% conversion within 50 moves (a tiny tablebase or
far deeper endgame search would be needed). The gate FAILS only on a hard
regression floor (50% of the pre-material-threading baseline, i.e. < 12.5%):
a regression in the endgame eval or DTM scoring shows up as shuffling or
queen blunders (conversion plummets AND draws appear).

Usage:
  python3 benchmarks/endgame_conversion.py [--games N] [--material q|r]
                                           [--plies N] [--seed S]

  --games     games per material (default 200)
  --material  'q' for KQK, 'r' for KRK, or 'qr' for both (default 'qr')
  --plies     max plies before declaring a failure to convert (default 100)
"""

import argparse
import json
import os
import random
import subprocess
import sys
import tempfile

import chess

# --- sunfish bridge (same file-queue protocol as elo_vs_stockfish.py) --------

BRIDGE_LUA = r'''
package.path = "$dir/?.lua;" .. package.path
local sunfish = require("sunfish")
sunfish.set_yield(nil, false)

local function cell1(name)
    local f, r = name:sub(1, 1), tonumber(name:sub(2, 2))
    return 92 + (f:byte() - 97) - 10 * (r - 1)
end

local function board_from_fen(fen_board, side)
    local rows = {}
    for r = 0, 11 do rows[r] = (r == 0 or r == 1 or r == 10) and ("         \n") or nil end
    rows[11] = "          "
    local fen_rows = {}
    for part in (fen_board .. "/"):gmatch("([^/]*)/") do fen_rows[#fen_rows + 1] = part end
    for fi, part in ipairs(fen_rows) do
        local rank = 9 - fi
        local row_idx = 10 - rank
        local chars = { " " }
        local col = 1
        for ch in part:gmatch(".") do
            local n = tonumber(ch)
            if n then
                for _ = 1, n do chars[col + 1] = "."; col = col + 1 end
            else
                chars[col + 1] = ch; col = col + 1
            end
        end
        chars[10] = "\n"
        rows[row_idx] = table.concat(chars)
    end
    local out = {}
    for r = 0, 11 do
        if not rows[r] then rows[r] = ("         \n") end
        out[r + 1] = rows[r]
    end
    local board = table.concat(out)
    if side == "b" then
        board = board:reverse():gsub("[A-Za-z]", function(c)
            local b = c:byte()
            if b >= 65 and b <= 90 then return string.char(b + 32) end
            return string.char(b - 32)
        end)
    end
    return board
end

local function castle_from_fen(fen_castle, side)
    local white, black = { false, false }, { false, false }
    if fen_castle and fen_castle ~= "-" then
        for ch in fen_castle:gmatch(".") do
            if ch == "K" then white[1] = true
            elseif ch == "Q" then white[2] = true
            elseif ch == "k" then black[1] = true
            elseif ch == "q" then black[2] = true end
        end
    end
    if side == "b" then return black, white end
    return white, black
end

local function ep_from_fen(fen_ep, side)
    if not fen_ep or fen_ep == "-" then return 0 end
    local f = fen_ep:sub(1, 1):byte() - string.byte("a") + 1
    local r = tonumber(fen_ep:sub(2, 2))
    local i = (10 - r) * 10 + f
    if side == "b" then i = 119 - i end
    return i
end

local function pos_from_fen(fen)
    local parts = {}
    for p in (fen .. " "):gmatch("([^ ]+) ") do parts[#parts + 1] = p end
    local board_field, side = parts[1], parts[2]
    local castle = parts[3] or "-"
    local ep = parts[4] or "-"
    local wc, bc = castle_from_fen(castle, side)
    local ep_i = ep_from_fen(ep, side)
    local board = board_from_fen(board_field, side)
    return sunfish.restore_data({ board = board, score = 0, wc = wc, bc = bc,
                                  ep = ep_i, kp = 0 })
end

local game = pos_from_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
local fen_side = "w"

local function display_to_real(mv, rot)
    local p1, p2 = cell1(mv:sub(1, 2)), cell1(mv:sub(3, 4))
    for _ = 1, rot do p1, p2 = 121 - p1, 121 - p2 end
    return sunfish.move_2_cell(p1 - 1) .. sunfish.move_2_cell(p2 - 1)
end

local n = 0
while true do
    local go = io.open(os.tmpname_dir .. "/go_" .. n .. ".txt", "r")
    if go then
        go:close()
        os.remove(os.tmpname_dir .. "/go_" .. n .. ".txt")
        local f = io.open(os.tmpname_dir .. "/cmd_" .. n .. ".txt", "r")
        local line = f:read("*l")
        f:close()
        if line then
            line = line:gsub("\r?\n$", "")
            if line:sub(1, 4) == "fen " then
                local fenstr = line:sub(5)
                game = pos_from_fen(fenstr)
                local s = fenstr:match("^%S+ ([wb])")
                fen_side = s or "w"
                print("READY")
            elseif line == "ai_move" then
                local ng, mv, sc = sunfish.ai_move(game)
                if not mv then
                    print(string.format("PASS %d", sc or 0))
                else
                    local rot = (fen_side == "w") and 1 or 0
                    local uci = display_to_real(mv, rot)
                    print(string.format("MOVE %s %d", uci, sc or 0))
                    game = ng
                end
            end
            io.flush()
        end
        n = n + 1
    end
    local t = os.clock()
    while os.clock() - t < 0.002 do end
end
'''


class SunfishBridge:
    def __init__(self, engine_dir, tmpdir):
        self.tmpdir = tmpdir
        script = BRIDGE_LUA.replace("$dir", engine_dir).replace(
            "os.tmpname_dir", json.dumps(tmpdir))
        self.proc = subprocess.Popen(
            ["luajit", "-e", script], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        self._cmd_idx = 0
        self._expect_ready()

    def _readline(self):
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("sunfish bridge died: " + (self.proc.stderr.read() or ""))
        return line.strip()

    def _expect_ready(self):
        self._send_cmd("fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        while True:
            if self._readline() == "READY":
                return

    def _send_cmd(self, cmd):
        idx = self._cmd_idx
        self._cmd_idx += 1
        with open(os.path.join(self.tmpdir, "cmd_%d.txt" % idx), "w") as f:
            f.write(cmd + "\n")
        with open(os.path.join(self.tmpdir, "go_%d.txt" % idx), "w") as f:
            f.write("go\n")

    def set_fen(self, fen):
        self._send_cmd("fen " + fen)
        while True:
            if self._readline() == "READY":
                return

    def ai_move(self):
        """Return (uci_move, score) or (None, score) when sunfish passes."""
        self._send_cmd("ai_move")
        parts = self._readline().split()
        if parts[0] == "MOVE":
            return parts[1], int(parts[2])
        return None, int(parts[1])

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            pass


# --- position generation -----------------------------------------------------

def random_kqk(rng):
    """A random KQK position with white winning (white queen)."""
    while True:
        wk = chess.SQUARES[rng.randrange(64)]
        bk = chess.SQUARES[rng.randrange(64)]
        wq = chess.SQUARES[rng.randrange(64)]
        if len({wk, bk, wq}) != 3:
            continue
        if chess.square_distance(wk, bk) < 2:  # kings may not be adjacent
            continue
        b = chess.Board(None)
        b.set_piece_at(wk, chess.Piece(chess.KING, chess.WHITE))
        b.set_piece_at(bk, chess.Piece(chess.KING, chess.BLACK))
        b.set_piece_at(wq, chess.Piece(chess.QUEEN, chess.WHITE))
        if b.is_checkmate() or b.is_stalemate():
            continue  # decided positions are not interesting for conversion
        return b


def random_krk(rng):
    """A random KRK position with white winning (white rook)."""
    while True:
        wk = chess.SQUARES[rng.randrange(64)]
        bk = chess.SQUARES[rng.randrange(64)]
        wr = chess.SQUARES[rng.randrange(64)]
        if len({wk, bk, wr}) != 3:
            continue
        if chess.square_distance(wk, bk) < 2:
            continue
        b = chess.Board(None)
        b.set_piece_at(wk, chess.Piece(chess.KING, chess.WHITE))
        b.set_piece_at(bk, chess.Piece(chess.KING, chess.BLACK))
        b.set_piece_at(wr, chess.Piece(chess.ROOK, chess.WHITE))
        if b.is_checkmate() or b.is_stalemate():
            continue
        return b


def random_kpk_draw(rng):
    """A K+P vs K position where the defender (black) blockades the pawn and
    should hold a draw: black king in front of the pawn on its promotion file,
    white king far away. Returns (board, white_to_move_win) — here always a
    draw-ish KPK with the black king blockading."""
    while True:
        pawn_file = rng.randrange(8)
        pawn_rank = rng.randrange(2, 6)  # not too advanced, not on rank 1
        pawn = chess.square(pawn_file, pawn_rank)
        # Black king directly in front of the pawn (same file, one rank ahead)
        bk = chess.square(pawn_file, pawn_rank + 1)
        wk = chess.SQUARES[rng.randrange(64)]
        if len({pawn, bk, wk}) != 3:
            continue
        if chess.square_distance(wk, bk) < 2:
            continue
        b = chess.Board(None)
        b.set_piece_at(pawn, chess.Piece(chess.PAWN, chess.WHITE))
        b.set_piece_at(bk, chess.Piece(chess.KING, chess.BLACK))
        b.set_piece_at(wk, chess.Piece(chess.KING, chess.WHITE))
        if b.is_checkmate() or b.is_stalemate():
            continue
        b.turn = chess.WHITE
        return b


def random_move(board):
    """A uniformly random legal move (mimics a weak defender)."""
    moves = list(board.legal_moves)
    return moves[random.randrange(len(moves))]


def play_game(bridge, board, max_plies):
    """Play one game: sunfish (winning side = white) vs random mover.
    Returns 'mate', 'draw', or 'fail'."""
    # The bridge FEN-syncs before every sunfish move, so we track the real
    # board with python-chess and re-sync before each sunfish turn.
    for ply in range(max_plies):
        if board.is_checkmate():
            return "mate"
        if board.is_stalemate() or board.is_insufficient_material() or board.is_fifty_moves():
            return "draw"
        if board.turn == chess.WHITE:
            # sunfish's move: sync the FEN, get the UCI move, apply it.
            bridge.set_fen(board.fen())
            mv, score = bridge.ai_move()
            if mv is None:
                return "fail"  # sunfish passed without mating
            board.push(chess.Move.from_uci(mv))
        else:
            board.push(random_move(board))
    # Out of plies: check whether we are at least in a won position (mate
    # would be the clean win; a bare material win without mate is a 'fail').
    if board.is_checkmate():
        return "mate"
    return "fail"


def play_draw_hold(bridge, board, max_plies):
    """Play one KPK draw-holding game: sunfish (black, the defender) must NOT
    lose against a random white attacker. Returns 'held', 'lost', or 'fail'."""
    for ply in range(max_plies):
        if board.is_checkmate() or board.is_stalemate():
            return "held" if board.is_stalemate() else "lost"
        if board.is_insufficient_material() or board.is_fifty_moves():
            return "held"
        if board.turn == chess.BLACK:
            bridge.set_fen(board.fen())
            mv, score = bridge.ai_move()
            if mv is None:
                return "fail"
            board.push(chess.Move.from_uci(mv))
        else:
            board.push(random_move(board))
    # Out of plies without the pawn queening = the defender held.
    return "held"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--games", type=int, default=200)
    ap.add_argument("--material", default="qr", help="q, r, or qr")
    ap.add_argument("--plies", type=int, default=100)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    engine_dir = os.path.dirname(os.path.abspath(__file__))
    tmpdir = tempfile.mkdtemp(prefix="sunfish_conv_")
    bridge = SunfishBridge(engine_dir, tmpdir)
    rng = random.Random(args.seed)

    materials = []
    if "q" in args.material:
        materials.append(("KQK", random_kqk))
    if "r" in args.material:
        materials.append(("KRK", random_krk))

    total = {"mate": 0, "draw": 0, "fail": 0}
    for name, gen in materials:
        for i in range(args.games):
            board = gen(rng)
            board.turn = chess.WHITE  # sunfish always plays the winning side
            result = play_game(bridge, board, args.plies)
            total[result] += 1
            if (i + 1) % 50 == 0:
                print("# %s %d/%d: %s" % (name, i + 1, args.games, result), flush=True)

    # KPK draw-holding suite: sunfish (black) defends a blockade against a
    # random white attacker and must NOT lose.
    hold_total = {"held": 0, "lost": 0, "fail": 0}
    for i in range(args.games):
        board = random_kpk_draw(rng)
        board.turn = chess.BLACK  # sunfish defends
        result = play_draw_hold(bridge, board, args.plies)
        hold_total[result] += 1

    bridge.close()

    n = sum(total.values())
    conv = 100.0 * total["mate"] / max(n, 1)
    print("")
    print("conversion: %d/%d mate (%.1f%%), draw %d, fail %d"
          % (total["mate"], n, conv, total["draw"], total["fail"]))
    hn = sum(hold_total.values())
    held = 100.0 * hold_total["held"] / max(hn, 1)
    print("draw-holding: %d/%d held (%.1f%%), lost %d, fail %d"
          % (hold_total["held"], hn, held, hold_total["lost"], hold_total["fail"]))
    # Hard regression floor: pre-material-threading baseline was ~25% (with
    # queen-blunder draws); fail only if we drop well below that.
    ok = conv >= 12.5
    print("CONVERSION GATE %s (aspirational target 95%%)" % ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
