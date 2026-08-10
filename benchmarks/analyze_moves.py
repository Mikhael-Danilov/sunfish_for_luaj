#!/usr/bin/env python3
"""Analyze move quality: % of legal top moves for sunfish and Stockfish.

Plays the same games as elo_vs_stockfish.py (same book, node levels, colors)
and, for every move by either engine, compares it against a strong reference
Stockfish's bestmove at a fixed high node budget. Also verifies every played
move is legal (via the FEN side-to-move flip trick).

Output per node level: for each engine, the number of moves examined, how many
were legal, and how many matched the reference's bestmove (the "top move").
The reference is deterministic at a fixed node count, so the same position
always yields the same reference move.

Usage:
  python3 benchmarks/analyze_moves.py [--engine DIR] [--stockfish PATH]
      [--ref "depth 14"] [--ref "nodes 50000"] [--nodes LIST] [--book PATH]
      [--plies N] [--seed N]

  --ref        reference Stockfish go-arg, e.g. 'depth 14' or 'nodes 50000'
               (default: depth 14). Must be stronger than the strongest level.
  --nodes      comma-separated node limits for the opponent Stockfish
               (default 20,50,100,300,1000,3000,10000,30000)
  --plies      max plies per game (default 40; analysis games can be shorter)
"""

import argparse
import os
import random
import select
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from elo_vs_stockfish import (  # noqa: E402
    DEFAULT_BOOK, SunfishBridge, Stockfish,
)


class RefStockfish(Stockfish):
    """Stockfish at the reference node budget, plus move legality checking.

    Every query is guarded by a wall-clock timeout (READ_TIMEOUT s). Under
    load, `go nodes N` can take far longer than its nominal budget (the VM
    has documented +/-30% variance), and a stuck query would otherwise hang
    the whole analysis.
    """

    READ_TIMEOUT = 60

    def __init__(self, path, ref_spec):
        # Unbuffered binary mode: select() needs a raw fd, and text-mode
        # TextIOWrapper buffers break the select/readline pairing. Detach
        # stdout BEFORE the base handshake so _readline (which selects on the
        # raw fd) works during it; _buf must exist first.
        self._buf = b""
        proc = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0)
        self.proc = proc
        # bufsize=0 gives a raw FileIO on stdout/stderr — no detach needed.
        self._send("uci")
        while self._readline().strip() != "uciok":
            pass
        self._send("setoption name Threads value 1")
        self._send("setoption name Hash value 16")
        # ref_spec is the literal Stockfish `go` argument, e.g. "depth 14" or
        # "nodes 50000". It must be stronger than the strongest level analyzed.
        self.ref_spec = ref_spec
        self.start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    def set_fen(self, fen):
        """Point the reference at a different starting (book) position."""
        self.start_fen = fen

    def _send(self, cmd):
        self.proc.stdin.write(cmd.encode() + b"\n")
        self.proc.stdin.flush()

    def close(self):
        try:
            self._send("quit")
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()

    def _readline(self):
        """Read one line with a wall-clock timeout (select on the raw fd).
        Accumulates into a byte buffer and splits on newline."""
        while b"\n" not in self._buf:
            r, _, _ = select.select([self.proc.stdout], [], [], self.READ_TIMEOUT)
            if not r:
                raise RuntimeError(
                    "reference stockfish read timeout (%ds)" % self.READ_TIMEOUT)
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("reference stockfish died")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        return line.decode() + "\n"

    def topmove(self, moves):
        """Return the reference bestmove for the position after `moves`,
        or None if the position is terminal (no legal move for the side to
        move — mate or stalemate)."""
        self._send("position startpos moves " + " ".join(moves))
        self._pos(moves)
        self._send("go " + self.ref_spec)
        while True:
            line = self._readline()
            if line.startswith("bestmove"):
                m = line.split()[1]
                return None if m == "(none)" else m

    def is_legal(self, moves_so_far, move):
        """True if `move` is legal after `moves_so_far` in the reference's
        start position. Uses the FEN side-to-move flip trick: a legal move
        advances the side to move; an illegal move is rejected by Stockfish and
        the position (and FEN side) stays unchanged."""
        def side(ms):
            self._pos(ms)
            self._send("d")
            while True:
                line = self._readline()
                if line.startswith("Fen:"):
                    return line.split()[2]  # "w" or "b"
        pre = side(moves_so_far)
        post = side(moves_so_far + [move])
        return post != pre


def play_analyzed(sf, ref, bridge, fen, plies, sf_color):
    """Play one game, recording per-move legality + top-move match for both
    engines. Returns (per-move list of (engine, move, legal, is_top), result)."""
    moves = []
    turn = 'w' if fen.split()[1] == 'w' else 'b'
    records = []
    for ply in range(plies):
        if turn == sf_color:
            m = sf.bestmove(moves)
            if m == "(none)":
                break
            engine = "stockfish"
        else:
            bridge.set_fen(sf.fen(moves))
            m, sc = bridge.ai_move()
            if m is None:
                break
            engine = "sunfish"
        # legality + top-move comparison against the reference
        legal = ref.is_legal(moves, m)
        top = ref.topmove(moves) if legal else None
        records.append((engine, m, legal, legal and top is not None and m == top))
        moves.append(m)
        turn = 'b' if turn == 'w' else 'w'
    result = sf.adjudicate(moves)
    return records, result


def main():
    ap = argparse.ArgumentParser(description="Analyze move quality vs Stockfish")
    ap.add_argument("--engine", default=os.getcwd())
    ap.add_argument("--stockfish",
                    default=".reference/stockfish/stockfish-ubuntu-x86-64-avx2")
    ap.add_argument("--ref", default="depth 14",
                    help="reference Stockfish go-arg, e.g. 'depth 14' or "
                         "'nodes 50000' (default: depth 14). Must be stronger "
                         "than the strongest level analyzed.")
    ap.add_argument("--nodes",
                    default="20,100,1000,3000")
    ap.add_argument("--book", default=None)
    ap.add_argument("--plies", type=int, default=40)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    sf_path = args.stockfish
    if not os.path.isabs(sf_path):
        sf_path = os.path.join(os.getcwd(), sf_path)
    if not os.path.exists(sf_path):
        print(f"stockfish not found: {sf_path}", file=sys.stderr)
        return 1

    node_levels = [int(x) for x in args.nodes.split(",")]
    book = DEFAULT_BOOK
    if args.book:
        with open(args.book) as f:
            book = [l.strip() for l in f if l.strip() and not l.startswith("#")]

    rng = random.Random(args.seed)
    combos = [(n, fen, color) for n in node_levels for fen in book for color in ("w", "b")]
    rng.shuffle(combos)

    # one reference Stockfish (deterministic at fixed strength)
    ref = RefStockfish(sf_path, args.ref)
    # aggregate: level -> engine -> {moves, legal, top}
    agg = {n: {"sunfish": {"n": 0, "legal": 0, "top": 0},
               "stockfish": {"n": 0, "legal": 0, "top": 0}} for n in node_levels}

    with tempfile.TemporaryDirectory(prefix="sunfish_analyze_") as tmpdir:
        bridge = SunfishBridge(args.engine, tmpdir)
        try:
            for nodes, fen, color in combos:
                ref.set_fen(fen)
                sf = Stockfish(sf_path, nodes, fen)
                try:
                    records, result = play_analyzed(sf, ref, bridge, fen,
                                                    args.plies, color)
                finally:
                    sf.close()
                for engine, move, legal, is_top in records:
                    a = agg[nodes][engine]
                    a["n"] += 1
                    if legal:
                        a["legal"] += 1
                    if is_top:
                        a["top"] += 1
                print(f"... analyzed level {nodes} ({len(records)} moves)", file=sys.stderr)
        finally:
            bridge.close()

    print("\n=== move quality vs reference Stockfish (%s) ===" % args.ref)
    hdr = f"{'nodes':>8} | {'sunfish':^28} | {'stockfish':^28}"
    print(hdr)
    print(f"{'':>8} | {'moves':>5} {'legal%':>7} {'top%':>7} {'top%lgl':>7} | "
          f"{'moves':>5} {'legal%':>7} {'top%':>7} {'top%lgl':>7}")
    for n in node_levels:
        row = []
        for engine in ("sunfish", "stockfish"):
            a = agg[n][engine]
            n_moves = a["n"]
            legal_pct = 100.0 * a["legal"] / n_moves if n_moves else 0.0
            top_pct = 100.0 * a["top"] / n_moves if n_moves else 0.0
            top_lgl_pct = 100.0 * a["top"] / a["legal"] if a["legal"] else 0.0
            row.append(f"{n_moves:>5} {legal_pct:>6.1f}% {top_pct:>6.1f}% {top_lgl_pct:>6.1f}%")
        print(f"{n:>8} | {row[0]} | {row[1]}")

    # illegality summary
    print("\n=== illegality ===")
    bad = 0
    for n in node_levels:
        for engine in ("sunfish", "stockfish"):
            a = agg[n][engine]
            illegal = a["n"] - a["legal"]
            if illegal:
                bad += illegal
                print(f"  nodes={n} {engine}: {illegal} illegal moves")
    if bad == 0:
        print("  all moves legal across all levels")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
