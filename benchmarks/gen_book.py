#!/usr/bin/env python3
"""Generate a compact Zobrist-keyed opening book for sunfish.

Positions are keyed by the engine's exact 32-bit Zobrist hash (see
zobrist_book.py), so a book lookup happens at the position level — the same
move is returned regardless of the move order that reached the position
(transposition-safe).

Entries come from two sources:
  1. Strong lines: play Stockfish (depth ~12) from each opening start and
     record both sides' moves for the first N plies.
  2. Classic trap lines (Scholar's mate, Fool's mate, Legal's mate, etc.):
     hand-written UCI move sequences that punish common weak replies.

Only book entries whose move is legal at the position are written (validated
with Stockfish's FEN side-to-move flip trick).

Output: a binary book of 16-byte Polyglot-style entries
  (8B key, 2B move, 2B weight, 2B learn=0), ~10KB.

Usage:
  python3 benchmarks/gen_book.py [--depth 12] [--plies 8] [--out BOOK]
      [--stockfish PATH]
"""

import argparse
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zobrist_book import (  # noqa: E402
    TABLES, pos_from_fen, zobrist_key, uci_to_poly, book_write,
)

# The 8 opening starts used by the Elo harness (the DEFAULT_BOOK).
START_FENS = [
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 1",     # e4 e5
    "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 1",     # Sicilian
    "rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 1",     # d4 d5
    "rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 1",     # d4 Nf6
    "rnbqkbnr/pppppppp/8/8/2P5/8/PP1PPPPP/RNBQKBNR b KQkq - 0 1",       # English
    "rnbqkbnr/ppp1pppp/8/3p4/8/5N2/PPPPPPPP/RNBQKB1R w KQkq - 0 1",     # Nf3 d5
    "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 1", # Italian-ish
]

# Classic trap lines (UCI move sequences). Each is a full game line; the book
# records every position along it (both sides), so sunfish gets book moves for
# both colors and for the opponent's book replies.
TRAP_LINES = [
    # Scholar's mate
    ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"],
    # Fool's mate (as black)
    ["f2f3", "e7e5", "g2g4", "d8h4"],
    # Legal's mate (the bishop trap: Nxe5 sacks the queen, then Bxf7+ Nd5#)
    ["e2e4", "e7e5", "g1f3", "d7d6", "f1c4", "c8g4", "b1c3", "g8f6",
     "f3e5", "g4d1", "c4f7", "e8e7", "c3d5"],
    # Fried Liver-ish (Italian: Nc3-f5 idea)
    ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6", "f3g5", "d7d5", "e4d5",
     "f6d5", "g5f7"],
    # Damiano / early Qh5 threat
    ["e2e4", "e7e5", "d1h5", "b8c6", "f1c4", "g8f6", "h5f7"],
    # King's Gambit-style open lines (gambit the f-pawn, develop fast)
    ["e2e4", "e7e5", "f2f4", "e5f4", "g1f3", "g7g5", "h2h4", "g5g4", "f3e5"],
    # Scandinavian center grab
    ["e2e4", "d7d5", "e4d5", "d8d5", "b1c3", "d5a5", "d2d4", "g8f6",
     "c1f4", "e7e6", "g1f3"],
    # London-system solid setup (both colors)
    ["d2d4", "d7d5", "c1f4", "g8f6", "e2e3", "e7e6", "g1f3", "f8d6", "f4d6",
     "d8d6", "b1d2"],
    # Queen's Gambit Declined-ish
    ["d2d4", "d7d5", "c2c4", "e7e6", "b1c3", "g8f6", "c1g5", "f8e7", "e2e3",
     "e8g8", "g1f3", "b8d7", "f1d3", "h7h6", "g5h4", "c7c5"],
    # Sicilian Najdorf-ish
    ["e2e4", "c7c5", "g1f3", "d7d6", "d2d4", "c5d4", "f3d4", "g8f6", "b1c3",
     "a7a6", "f1e2", "e7e5", "d4b3"],
    # KIA / King's Indian setup
    ["g1f3", "g8f6", "g2g3", "g7g6", "f1g2", "f8g7", "e2e4", "e7e5",
     "e1g1", "e8g8", "d2d4"],
]


class Stockfish:
    def __init__(self, path):
        self.proc = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self._send("uci")
        while self._readline().strip() != "uciok":
            pass
        self._send("setoption name Threads value 1")
        self._send("setoption name Hash value 16")

    def _send(self, cmd):
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()

    def _readline(self):
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("stockfish died")
        return line

    def _pos(self, fen, moves):
        self._send("position fen %s moves %s" % (fen, " ".join(moves)))

    def bestmove(self, fen, moves, depth=12):
        """Bestmove for the position after `moves` from base FEN `fen`."""
        self._pos(fen, moves)
        self._send("go depth %d" % depth)
        while True:
            line = self._readline()
            if line.startswith("bestmove"):
                m = line.split()[1]
                return None if m == "(none)" else m

    def topmoves(self, fen, branch, depth=12):
        """The top `branch` moves for `fen` via MultiPV (deterministic at a
        fixed depth). Returns a list of UCI moves (possibly shorter if the
        position has fewer legal moves)."""
        self._pos(fen, [])
        self._send("setoption name MultiPV value %d" % branch)
        self._send("go depth %d" % depth)
        moves = []
        while True:
            line = self._readline()
            if line.startswith("info"):
                # info depth D multipv K score ... pv m1 m2 ...
                if " pv " in line:
                    mv = line.split(" pv ")[1].split()[0]
                    if mv not in moves:
                        moves.append(mv)
            elif line.startswith("bestmove"):
                break
        return moves

    def fen_side(self, fen, moves):
        self._pos(fen, moves)
        self._send("d")
        while True:
            line = self._readline()
            if line.startswith("Fen:"):
                return line.split()[2]

    def is_legal(self, fen, moves, move):
        pre = self.fen_side(fen, moves)
        post = self.fen_side(fen, moves + [move])
        return post != pre

    def fen(self, fen, moves):
        self._pos(fen, moves)
        self._send("d")
        while True:
            line = self._readline()
            if line.startswith("Fen:"):
                return " ".join(line.split()[1:5])

    def apply_move(self, fen, uci):
        """Return the FEN after `uci` from `fen`."""
        return self.fen(fen, [uci])

    def close(self):
        try:
            self._send("quit")
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def _fen_key(fen):
    codes, wc, bc, ep, kp = pos_from_fen(fen)
    return zobrist_key(codes, wc, bc, ep, kp, TABLES)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--depth", type=int, default=12)
    ap.add_argument("--plies", type=int, default=8,
                    help="max plies of SF-generated lines to record per start")
    ap.add_argument("--branch", type=int, default=1,
                    help="MultiPV width: top-N moves to explore at each ply "
                         "(1 = single best line, 3 = 3x branching)")
    ap.add_argument("--out", default="benchmarks/sunfish.bin")
    ap.add_argument("--stockfish",
                    default=".reference/stockfish/stockfish-ubuntu-x86-64-avx2")
    args = ap.parse_args()

    sf_path = args.stockfish
    if not os.path.isabs(sf_path):
        sf_path = os.path.join(os.getcwd(), sf_path)
    if not os.path.exists(sf_path):
        print(f"stockfish not found: {sf_path}", file=sys.stderr)
        return 1

    entries = {}  # key32 -> poly move16 (dedupe; last write wins)

    def record(fen, move):
        key = _fen_key(fen)
        entries[key] = uci_to_poly(move)

    sf = Stockfish(sf_path)
    try:
        # 1) Classic trap lines (explicit move sequences, from the standard
        #    start position). Run FIRST so the stronger SF lines below can
        #    overwrite them on the same positions (last write wins).
        for line in TRAP_LINES:
            fen = START_FENS[0]
            for m in line:
                if not sf.is_legal(fen, [], m):
                    print(f"  skipping illegal trap move {m} from {fen[:20]}...",
                          file=sys.stderr)
                    break
                key = _fen_key(fen)
                entries[key] = uci_to_poly(m)
                fen = sf.apply_move(fen, m)

        # 2) Strong lines: branch through the top-N Stockfish moves at each
        #    position (MultiPV), recording position -> move for every ply of
        #    every branch. Covers both colors (SF plays both sides) and the
        #    opponent's most-likely deviations.
        def expand(fen, ply):
            if ply >= args.plies:
                return
            tops = sf.topmoves(fen, args.branch, depth=args.depth)
            if not tops:
                return
            for m in tops:
                if not sf.is_legal(fen, [], m):
                    print(f"  skipping illegal SF move {m} from {fen[:20]}...",
                          file=sys.stderr)
                    continue
                record(fen, m)
                expand(sf.apply_move(fen, m), ply + 1)

        for start in START_FENS:
            expand(start, 0)

    finally:
        sf.close()

    print(f"entries: {len(entries)}  size: {len(entries)*16} bytes")
    book_write([(k, mv, 1) for k, mv in sorted(entries.items())], args.out)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
