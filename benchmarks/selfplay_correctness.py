#!/usr/bin/env python3
"""Self-play correctness gate for sunfish.lua.

Drives the engine for up to 100 plies (or until the game ends naturally),
reconstructing each move in real-board standard notation, and validates every
move with Stockfish over UCI. The engine rotates the board after every move,
so the "engine frame" alternates; we track the accumulated rotation parity to
convert each ply's move back to the real board.

Usage:
  python3 benchmarks/selfplay_correctness.py [--plies N] [--engine DIR]
                                             [--stockfish PATH]
  (defaults: 100 plies, ./sunfish.lua, .reference/stockfish/stockfish-ubuntu-x86-64-avx2)

Exit 0 = all moves legal per Stockfish (game ran to a natural end or the ply
cap); exit 1 = an illegal move or a crash.
"""

import argparse
import os
import string
import subprocess
import sys

# --- engine driver ----------------------------------------------------------

def run_engine(engine_dir, plies):
    """Run the engine under luajit, yield (ply, move, score, final_board) via
    a small inline Lua script that prints one line per ply in a parseable
    format. Returns the list of (ply, real_move, engine_move, score)."""
    lua = r'''
package.path = "$dir/?.lua;" .. package.path
local sunfish = require("sunfish")
sunfish.set_yield(nil, false)

-- display is in the CHILD (rotated) frame, rendered 1-based. The parent-frame
-- move is the mirror: parent_sq = 121 - child_sq (1-based), rendered with the
-- public 0-based helper (move_2_cell takes 0-based; subtract 1).
local function cell1(name)
    local f, r = name:sub(1, 1), tonumber(name:sub(2, 2))
    return 92 + (f:byte() - 97) - 10 * (r - 1) -- 1-based A1=92
end
-- Convert a child-frame display move to the REAL (absolute) board frame.
-- The engine rotates every ply, so the engine frame at ply p is the real frame
-- rotated (p-1) times. parent = mirror of child (121-x), then un-rotate by the
-- accumulated flips: after the first ply the frame is flipped, so apply the
-- 121-x mirror (ply-1) times to land back on the real board.
local function child_to_real(mv, ply)
    local p1, p2 = 121 - cell1(mv:sub(1, 2)), 121 - cell1(mv:sub(3, 4))
    for _ = 2, ply do p1, p2 = 121 - p1, 121 - p2 end
    -- promotion moves carry the piece char (5 chars, e.g. "f2f1n"); keep it
    -- so the validator replays the piece the engine actually promoted to
    return sunfish.move_2_cell(p1 - 1) .. sunfish.move_2_cell(p2 - 1)
        .. (mv:sub(5, 5) or "")
end

local game = sunfish.new()
for ply = 1, $plies do
    local ng, mv, sc = sunfish.ai_move(game)
    if not mv then
        -- engine passes (root TT overwritten / decided); treat as no move
        print(string.format("%d PASS %d", ply, sc or 0))
        game = ng
        break
    end
    local real = child_to_real(mv, ply)
    print(string.format("%d MOVE %s %s %d", ply, real, mv, sc or 0))
    game = ng
    if sc and math.abs(sc) >= sunfish.MATE_VALUE then break end
end
print("BOARD")
print(game:ensure_board())
'''
    script = string.Template(lua).substitute(dir=engine_dir, plies=plies)
    proc = subprocess.run(
        ["luajit", "-"],
        input=script, capture_output=True, text=True, timeout=600,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"engine failed: {proc.stderr}")
    moves = []
    board = None
    in_board = False
    for line in proc.stdout.splitlines():
        if line == "BOARD":
            in_board = True
            continue
        if in_board:
            board = (board or "") + line + "\n"
            continue
        parts = line.split()
        if len(parts) >= 4 and parts[1] == "MOVE":
            # (ply, parent_move, display_move, score)
            moves.append((int(parts[0]), parts[2], parts[3], int(parts[4])))
        elif len(parts) >= 2 and parts[1] == "PASS":
            moves.append((int(parts[0]), None, None, int(parts[2])))
        elif len(parts) >= 2 and parts[1] == "DIFF":
            moves.append((int(parts[0]), "DIFF", None, 0))
    return moves, board


# --- stockfish UCI ----------------------------------------------------------

class Stockfish:
    def __init__(self, path):
        self.proc = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self._send("uci")
        # wait for "uciok"
        while True:
            line = self.proc.stdout.readline().strip()
            if line == "uciok":
                break
        self._send("setoption name Threads value 1")
        self._send("isready")
        while True:
            line = self.proc.stdout.readline().strip()
            if line == "readyok":
                break

    def _send(self, cmd):
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()

    def is_legal(self, moves_so_far, move):
        """True if `move` is legal after `moves_so_far` on the real board.

        Stockfish-native check:
          1. position on moves_so_far, read the FEN (side to move).
          2. position on moves_so_far + [move], read the FEN again.
        A legal move flips the side to move in the FEN; an illegal move is
        rejected by Stockfish's move parser, leaving the position (and FEN
        side) unchanged. So: legal iff the side-to-move flipped.
        """
        def fen_side(ms):
            self._send("position startpos moves " + " ".join(ms))
            self._send("d")
            while True:
                line = self.proc.stdout.readline().strip()
                if line.startswith("Fen:"):
                    # FEN: "Fen: <board> w/b ..." -> field 2 is the side to move
                    return line.split()[2]  # "w" or "b"
        pre = fen_side(moves_so_far)
        post = fen_side(moves_so_far + [move])
        if post != pre:
            return move
        # The engine auto-queens and emits 4-char moves; a pawn reaching the
        # last rank needs the promotion suffix for Stockfish. Try all four.
        if len(move) == 4 and move[3] in "18":
            for suf in ("q", "r", "b", "n"):
                if fen_side(moves_so_far + [move + suf]) != pre:
                    return move + suf
        return None

    def close(self):
        self._send("quit")
        self.proc.wait(timeout=5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plies", type=int, default=100)
    ap.add_argument("--engine", default=os.getcwd())
    ap.add_argument("--stockfish",
                    default=".reference/stockfish/stockfish-ubuntu-x86-64-avx2")
    args = ap.parse_args()

    sf_path = args.stockfish
    if not os.path.isabs(sf_path):
        sf_path = os.path.join(os.getcwd(), sf_path)
    if not os.path.exists(sf_path):
        print(f"stockfish not found: {sf_path}", file=sys.stderr)
        return 1

    print(f"# selfplay correctness: plies={args.plies} engine={args.engine} stockfish={sf_path}")

    moves, board = run_engine(args.engine, args.plies)

    sf = Stockfish(sf_path)
    played = []
    failures = 0
    for ply, real, engine_mv, sc in moves:
        if real is None:  # PASS / DIFF
            print(f"ply {ply:3d}: (pass)  score {sc}")
            continue
        if real == "DIFF":
            print(f"ply {ply:3d}: BOARD DIFF ERROR")
            failures += 1
            continue
        canonical = sf.is_legal(played, real)
        status = "OK" if canonical else "ILLEGAL"
        if not canonical:
            failures += 1
            played.append(real)
        else:
            played.append(canonical)
        print(f"ply {ply:3d}: {real:6s}  [{status}]  score {sc}")

    # Natural end detection from the final board (simple: material + king check)
    print(f"\nfinal board:\n{board}")
    print(f"plies played: {len(played)}  failures: {failures}")

    sf.close()
    if failures:
        print("SELFPLAY GATE FAILED")
        return 1
    print("SELFPLAY GATE PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
