#!/usr/bin/env python3
"""Cross-validate sunfish.lua's legal move generation against python-chess."""
import chess
import subprocess
import sys

LUA_DRIVER = r'''
package.path = "/home/nyrds/sunfish/?.lua;" .. package.path
local sunfish = require("sunfish")

local function build_board(placements)
  local rows = {}
  rows[0] = "         \n"; rows[1] = "         \n"
  rows[10] = "         \n"; rows[11] = "          "
  for r = 2, 9 do
    local row = { " " }
    for c = 1, 8 do row[c+1] = "." end
    row[10] = "\n"
    rows[r] = table.concat(row)
  end
  for cell, piece in pairs(placements) do
    local f, r = cell:sub(1,1), tonumber(cell:sub(2,2))
    local i = (10 - r) * 10 + (f:byte() - string.byte("a") + 1)
    local row = math.floor(i / 10); local col = i % 10
    rows[row] = rows[row]:sub(1, col) .. piece .. rows[row]:sub(col + 2)
  end
  local out = {}
  for r = 0, 11 do out[r+1] = rows[r] end
  return table.concat(out)
end

local function render(i)
  local rank, fil = math.floor((i - 92)/10), (i - 92) % 10
  return string.char(fil + string.byte("a")) .. tostring(-rank + 1)
end

-- Read placements from stdin as lines "cell piece"
local placements = {}
for line in io.lines() do
  if line ~= "" then
    local cell, piece = line:match("(%w%d) (%w)")
    placements[cell] = piece
  end
end

local g = sunfish.restore_data({ board = build_board(placements), score = 0,
  wc = {false,false}, bc = {false,false}, ep = 0, kp = 0 })

-- sunfish frame: uppercase = side to move.
-- Output legal moves as uci (from-square + to-square, both rendered in frame).
local legal = sunfish.legal_moves(g)
local out = {}
for _, m in ipairs(legal) do
  local mi = math.floor(m / 128) % 128
  local mj = m % 128
  out[#out+1] = render(mi) .. render(mj)
end
table.sort(out)
io.write(table.concat(out, ","))
io.write("\n")
io.write("in_check=" .. tostring(sunfish.in_check(g)) .. "\n")
io.write("mate=" .. tostring(sunfish.is_checkmate(g)) .. "\n")
io.write("stale=" .. tostring(sunfish.is_stalemate(g)) .. "\n")
'''

# test positions: (fen, name)
POSITIONS = [
    # (FEN, label) - uppercase in sunfish = side to move = the side that is to move in FEN
    ("8/6Q1/8/8/8/8/4K3/7k w - - 0 1", "KQK basic"),
    ("7k/6Q1/5K2/8/8/8/8/8 w - - 0 1", "KQK Kf7 mate-in-1"),
    ("4k3/8/8/8/8/8/8/4R1K1 w - - 0 1", "KRK edge"),
    ("8/8/8/8/8/2K5/8/R6k w - - 0 1", "KRK Ra1+ mate"),
    ("8/8/8/8/8/8/4k3/R6K w - - 0 1", "KRK rank mate"),
    ("k7/8/8/8/8/8/8/KR6 w - - 0 1", "KRK corner"),
    ("8/8/8/3k4/8/8/8/KQ6 w - - 0 1", "KQK center"),
    ("8/5k2/8/8/8/8/8/KQ6 w - - 0 1", "KQK edge kf7"),
    ("7k/8/8/8/8/8/8/KQ6 w - - 0 1", "KQK h8 corner"),
    ("8/5k2/8/8/8/8/8/K6R w - - 0 1", "KRK Rh1"),
    ("6k1/8/8/8/8/8/8/K6R w - - 0 1", "KRK Rh1 g8"),
    ("k7/8/8/8/8/8/8/1R4K1 w - - 0 1", "KRK Rb1"),
    ("4k3/4P3/8/8/8/8/8/4K3 w - - 0 1", "KPK e7 pawn"),
    ("8/8/8/3k4/8/8/8/K3P3 w - - 0 1", "KPK e2 pawn"),
    ("8/8/8/3k4/3P4/8/8/K7 w - - 0 1", "KPK d4 pawn"),
    ("8/8/8/8/3k4/8/8/K2N4 w - - 0 1", "KNK Nd2"),
    ("k7/8/8/8/8/8/8/KN6 w - - 0 1", "KNK Nb1"),
    ("8/8/8/8/3k4/8/8/KB6 w - - 0 1", "KBK Bb1"),
    ("4k3/8/8/8/8/8/8/KB6 w - - 0 1", "KBK Bb1 ke8"),
    # Checkmate / stalemate positions
    ("6k1/5ppp/8/8/8/8/8/4R1K1 w - - 0 1", "white R to mate g8?"),
    ("7k/5ppp/8/8/8/8/8/4R1K1 w - - 0 1", "white R mate h8"),
    ("6k1/5ppp/5R2/8/8/8/8/6K1 b - - 0 1", "back-rank mate (black mated)"),
    ("6k1/6pp/8/8/8/8/8/R5K1 w - - 0 1", "KRK w Ra8#?"),
    ("k7/8/1K6/8/8/8/8/8 w - - 0 1", "K vs K (draw)"),
    ("k7/8/1K6/8/8/8/8/1R6 w - - 0 1", "KRK Kb7?"),
    ("8/8/8/8/8/2K5/8/R6k w - - 0 1", "KRK Ra1+ h1?"),
    ("8/8/8/8/8/8/1k6/R3K3 b - - 0 1", "KRK b2 black to move"),
    ("8/8/3k4/8/8/8/8/1R2K3 b - - 0 1", "KRK d6 black"),
    ("8/8/8/8/8/8/k7/R3K3 w - - 0 1", "KRK a2 white"),
    ("6k1/5p2/8/8/8/8/8/4R1K1 w - - 0 1", "KRK f7 pawn"),
    ("8/8/8/8/8/8/5k2/4R1K1 w - - 0 1", "KRK f2 black"),
    ("k7/8/8/8/8/8/8/4R1K1 b - - 0 1", "KRK a8 black to move"),
    ("8/8/8/8/8/8/4k3/4R1K1 b - - 0 1", "KRK e2 black"),
    # Stalemates
    ("k7/8/1Q6/8/8/8/8/K7 b - - 0 1", "stalemate: Ka8 Qb6"),
    ("7k/8/8/8/8/8/8/K6Q w - - 0 1", "KQh1 vs kh8"),
    ("7k/8/5Q2/8/8/8/8/K7 b - - 0 1", "KQ f6 vs kh8?"),
    # Pawn promotion
    ("4k3/4P3/8/8/8/8/8/4K3 w - - 0 1", "KPK e7e8 promo"),
    ("4k3/4P3/8/8/8/8/8/4K3 b - - 0 1", "KPK e7 black to move"),
    # Minor piece
    ("k7/8/8/8/8/8/8/KN6 b - - 0 1", "KNK Nb1 black"),
    ("k7/8/8/8/8/8/8/KB6 b - - 0 1", "KBK Bb1 black"),
]

def sunfish_placements_from_fen(fen):
    """Convert a FEN board to sunfish placements dict.
    sunfish frame: side to move pieces are UPPERCASE.
    python-chess FEN: white uppercase, black lowercase, white to move.
    If black to move, we rotate: swap case.
    """
    board = fen.split()[0]
    rows = board.split("/")
    placements = {}
    side = fen.split()[1]  # 'w' or 'b'
    # FEN row 8 first. sunfish row index (0-based) for rank r: (10 - r)
    for fi, row in enumerate(rows):
        rank = 8 - fi
        col = 1  # a=1
        for ch in row:
            if ch.isdigit():
                col += int(ch)
            else:
                file_letter = chr(ord("a") + col - 1)
                cell = f"{file_letter}{rank}"
                piece = ch
                if side == "b":
                    # Engine invariant: the side to move sits at the bottom.
                    # For black to move, rotate the whole board 180deg and swap
                    # case so black's pieces are uppercase at the bottom.
                    def rot(cc):
                        return chr(ord("h") - (ord(cc[0]) - ord("a"))) + str(9 - int(cc[1]))
                    cell = rot(cell)
                    piece = piece.swapcase()
                placements[cell] = piece
                col += 1
    return placements

def run_sunfish(placements):
    inp = "".join(f"{cell} {piece}\n" for cell, piece in sorted(placements.items()))
    proc = subprocess.run(["luajit", "-e", LUA_DRIVER], input=inp,
                          capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        return None, proc.stderr.strip()
    lines = proc.stdout.strip().split("\n")
    moves = set()
    flags = {}
    for l in lines:
        if l.startswith("in_check="):
            flags["check"] = l.split("=")[1] == "true"
        elif l.startswith("mate="):
            flags["mate"] = l.split("=")[1] == "true"
        elif l.startswith("stale="):
            flags["stale"] = l.split("=")[1] == "true"
        elif l != "":
            moves = set(l.split(","))
        if l.startswith("in_check="):
            flags["check"] = l.split("=")[1] == "true"
        elif l.startswith("mate="):
            flags["mate"] = l.split("=")[1] == "true"
        elif l.startswith("stale="):
            flags["stale"] = l.split("=")[1] == "true"
    return moves, flags


def strip_king_captures(board, py_moves):
    """Remove moves that land on the enemy king's square (python-chess includes
    them as pseudo-legal 'capture the king' moves; standard chess does not)."""
    enemy_king = chess.BLACK if board.turn == chess.WHITE else chess.WHITE
    king_sq = board.king(enemy_king)
    if king_sq is None:
        return py_moves
    return {m for m in py_moves if chess.parse_square(m[2:4]) != king_sq}

def main():
    failures = 0
    for fen, name in POSITIONS:
        board = chess.Board(fen)
        placements = sunfish_placements_from_fen(fen)
        sf_moves, sf_flags = run_sunfish(placements)
        if sf_moves is None:
            print(f"FAIL {name}: lua error {sf_flags}")
            failures += 1
            continue
        py_moves = set(m.uci() for m in board.legal_moves)
        # Strip king-captures in the RAW frame first (the strip helper uses
        # python-chess's own square indices), then rotate into the engine frame.
        py_moves = strip_king_captures(board, py_moves)
        if fen.split()[1] == "b":
            # The engine rotates the board 180deg (reverse + case swap) after
            # every move, so black-to-move positions are shown in the rotated
            # frame: (file, rank) -> (9-file+1, 9-rank). Mirror both axes.
            def rot(coord):
                f = chr(ord("h") - (ord(coord[0]) - ord("a")))
                return f + str(9 - int(coord[1]))
            py_moves = {rot(m[:2]) + rot(m[2:]) for m in py_moves}
        only_sf = sf_moves - py_moves
        only_py = py_moves - sf_moves
        if only_sf or only_py:
            print(f"MISMATCH {name} ({fen})")
            if only_sf:
                print(f"  only sunfish: {sorted(only_sf)}")
            if only_py:
                print(f"  only python-chess: {sorted(only_py)}")
            failures += 1
        else:
            print(f"ok {name}: {len(py_moves)} moves, check={sf_flags.get('check')} mate={sf_flags.get('mate')} stale={sf_flags.get('stale')}")
        # compare flags
        if sf_flags.get("mate") != board.is_checkmate():
            print(f"  FLAG MISMATCH mate: sunfish={sf_flags.get('mate')} py={board.is_checkmate()}")
            failures += 1
        if sf_flags.get("stale") != board.is_stalemate():
            print(f"  FLAG MISMATCH stale: sunfish={sf_flags.get('stale')} py={board.is_stalemate()}")
            failures += 1
    print(f"\n{len(POSITIONS) - failures}/{len(POSITIONS)} positions matched")
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
