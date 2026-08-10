#!/usr/bin/env python3
"""Estimate sunfish.lua's Elo strength by pairing it against Stockfish.

sunfish (a ~10k-node/0.1s-per-move engine under luajit) plays full games
against a local Stockfish 18 over UCI. Stockfish strength is scaled with
`go nodes N` (deterministic and load-immune, unlike movetime), and sunfish's
strength is estimated from the win/draw/loss rates against each Stockfish
node limit.

Methodology notes (matching the repo's benchmark taste):
  - Deterministic opponent: Stockfish at a fixed node count is deterministic
    from a fixed position, so all games from one FEN are identical. Game
    variety comes from a fixed book of opening FENs (standard practice when
    pairing a weak engine against a deterministic strong one). With the
    default seed the opening order is shuffled deterministically.
  - sunfish runs as a persistent luajit subprocess speaking a line protocol
    (one module load + warm-up per process, not per move). The bridge reuses
    the rotation-parity UCI conversion from selfplay_correctness.py and the
    FEN builder from tests/test_perft.lua.
  - sunfish's per-move cost is ~0.1s under luajit (10k-node budget), so a
    60-ply game is ~3s of sunfish time; hundreds of games are feasible.
  - Games are adjudicated by a final Stockfish probe (mate/stalemate or
    draw); the ply cap is a draw.

Usage:
  python3 benchmarks/elo_vs_stockfish.py [--engine DIR] [--stockfish PATH]
      [--games N] [--plies N] [--nodes LIST] [--book PATH] [--seed N]

  --engine     dir containing sunfish.lua (default: repo root)
  --stockfish  path to the stockfish binary
  --games      games per (node-level, opening) combination (default 1;
               deterministic opponent + fixed book means 1 game per opening
               per level is enough; raise to add more openings/repeats)
  --plies      max plies per game before adjudicating a draw (default 80)
  --nodes      comma-separated Stockfish node limits (default
               20,50,100,300,1000,3000,10000,30000)
  --book       file of opening FENs, one per line (default: built-in set)
  --seed       RNG seed for game order (default 1)

Exit 0 on success; prints a per-level win-rate table + Elo estimate per
level (logistic Elo anchored on a rough Stockfish node-count strength curve)
and the overall maximum-likelihood fitted Elo.
"""

import argparse
import json
import math
import os
import random
import subprocess
import sys
import tempfile

DEFAULT_BOOK = [
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 1",     # e4 e5
    "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 1",     # Sicilian
    "rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 1",     # d4 d5
    "rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 1",     # d4 Nf6
    "rnbqkbnr/pppppppp/8/8/2P5/8/PP1PPPPP/RNBQKBNR b KQkq - 0 1",       # English
    "rnbqkbnr/ppp1pppp/8/3p4/8/5N2/PPPPPPPP/RNBQKB1R w KQkq - 0 1",     # Nf3 d5
    "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 1", # Italian-ish
]

# Rough Stockfish-18 strength anchor vs node limit (log-scale): ~1350 Elo at
# 10 nodes, ~+350 Elo per 100x nodes, capped at ~2900. These are approximate;
# the per-level table and the ML fit inherit this anchor's uncertainty. The
# primary signal is the win-rate table itself.
def sf_elo_anchor(nodes):
    return 1350 + 350 * math.log10(max(nodes, 1) / 10.0)

# Adjudication threshold: a Stockfish CP advantage this large (from the side to
# move) declares a decisive result at the ply cap / pass. 800cp = up a full
# minor piece with a clear position — practically certain.
ADJUDICATE_CP = 800
# Node budget for the per-game adjudication probe. 50k nodes spots any
# mating line a weak engine is likely to hit and any 800+cp advantage; high
# enough for decisive-call reliability, low enough to keep the run fast on a
# shared/loud VM.
ADJUDICATE_NODES = 50000


# --- sunfish bridge ----------------------------------------------------------
#
# NOTE: luajit's `io.stdin:read("*l")` on a pipe does not return lines until
# EOF or a full buffer (verified experimentally), so a persistent line-protocol
# child over stdin hangs. The bridge instead uses a file-based command queue:
# the Python side writes cmd_<n>.txt + go_<n>.txt; the luajit child polls for
# go_<n>.txt (busy-wait, ~2ms granularity), reads the command, and prints the
# reply to stdout (which flushes fine). ~10ms round-trip per command.

BRIDGE_LUA = r'''
package.path = "$dir/?.lua;" .. package.path
local sunfish = require("sunfish")
sunfish.set_yield(nil, false)

local function cell1(name)
    local f, r = name:sub(1, 1), tonumber(name:sub(2, 2))
    return 92 + (f:byte() - 97) - 10 * (r - 1)
end

-- FEN -> engine position (port of tests/test_perft.lua's pos_from_fen)
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

-- game state
local game = pos_from_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
local plies = 0 -- total moves played (frame rotations) since the last new/fen
local fen_side = "w" -- side to move in the current FEN (the bridge's frame)

-- Convert a display move (child frame, rendered 1-based) to a real-board UCI
-- move. Matching selfplay_correctness.py: the gate applies `ply` mirrors total
-- (odd ply = 1 net mirror, even ply = identity). In the FEN-sync bridge each
-- ai_move is a fresh ply: white-to-move FEN = odd ply = 1 mirror; black-to-move
-- FEN = even ply = 0 mirrors. `rot` is that net mirror count (1 or 0).
local function display_to_real(mv, rot)
    local p1, p2 = cell1(mv:sub(1, 2)), cell1(mv:sub(3, 4))
    for _ = 1, rot do p1, p2 = 121 - p1, 121 - p2 end
    return sunfish.move_2_cell(p1 - 1) .. sunfish.move_2_cell(p2 - 1)
end

-- File-poll command loop: Python writes cmd_<n>.txt + go_<n>.txt to the
-- bridge dir; we busy-poll for go_<n>.txt (fine granularity via os.clock),
-- read the command, and print the reply to stdout.
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
            line = line:gsub("\r?\n$", "")  -- strip trailing newline only
            if line == "new" then
                game = pos_from_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
                plies = 0
                fen_side = "w"
                print("READY")
            elseif line:sub(1, 4) == "fen " then
                -- Rebuild the position from a real-board FEN. The engine's
                -- convention: side to move uppercase at the bottom, castling
                -- rights swapped for black to move, ep mirrored. pos_from_fen
                -- handles all of that. `plies` is reset because the frame is
                -- freshly built (the FEN is the current frame).
                local fenstr = line:sub(5)
                game = pos_from_fen(fenstr)
                plies = 0
                local s = fenstr:match("^%S+ ([wb])")
                fen_side = s or "w"
                print("READY")
            elseif line:sub(1, 4) == "time" then
                sunfish.set_time_budget(tonumber(line:sub(6) or "0"))
                print("READY")
            elseif line == "ai_move" then
                local ng, mv, sc = sunfish.ai_move(game)
                if not mv then
                    print(string.format("PASS %d", sc or 0))
                else
                    -- Parity: white-to-move FEN = odd ply = 1 mirror;
                    -- black-to-move FEN = even ply = 0 mirrors.
                    local rot = (fen_side == "w") and 1 or 0
                    local uci = display_to_real(mv, rot)
                    print(string.format("MOVE %s %d", uci, sc or 0))
                    game = ng
                    plies = plies + 1
                end
            end
            io.flush()
        end
        n = n + 1
    end
    -- small busy delay (~2ms) so the poll doesn't starve the OS
    local t = os.clock()
    while os.clock() - t < 0.002 do end
end
'''


class SunfishBridge:
    """Persistent luajit subprocess speaking a file-queue protocol.

    luajit's `io.stdin:read("*l")` blocks on an open pipe (verified), so
    commands go through numbered files in a temp dir; the child polls for a
    `go_<n>.txt` marker and prints replies to stdout (which flushes fine).
    ~10ms round-trip per command — negligible vs ~0.1s per ai_move.
    """

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
        self._send_cmd("new")
        while True:
            line = self._readline()
            if line == "READY":
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
            line = self._readline()
            if line == "READY":
                return

    def set_time_budget(self, seconds):
        self._send_cmd("time " + str(seconds))
        while True:
            if self._readline() == "READY":
                return

    def ai_move(self):
        """Return (uci_move, score) for the current position, or (None, score)
        when sunfish passes (decided position / root TT overwritten)."""
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


# --- stockfish UCI -----------------------------------------------------------

class Stockfish:
    def __init__(self, path, nodes, start_fen):
        self.proc = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self._send("uci")
        while self._readline().strip() != "uciok":
            pass
        self._send("setoption name Threads value 1")
        self._send("setoption name Hash value 16")
        self.nodes = nodes
        self.start_fen = start_fen  # the book FEN this game starts from

    def _send(self, cmd):
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()

    def _readline(self):
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("stockfish died")
        return line

    def _pos(self, moves):
        """Set up the book position then apply `moves` (loaded from the FEN,
        not startpos, so non-starting openings are played correctly)."""
        self._send("position fen %s moves %s" % (
            self.start_fen, " ".join(moves)))

    def bestmove(self, moves):
        """bestmove (uci) for `moves` from the book position, or '(none)'."""
        self._pos(moves)
        self._send("go nodes %d" % self.nodes)
        while True:
            line = self._readline()
            if line.startswith("bestmove"):
                return line.split()[1]

    def fen(self, moves):
        """The FEN after `moves` from the book position."""
        self._pos(moves)
        self._send("d")
        while True:
            line = self._readline()
            if line.startswith("Fen:"):
                return " ".join(line.split()[1:5])

    def adjudicate(self, moves):
        """Probe the position after `moves`; return '1-0' / '0-1' / '1/2-1/2'.

        Decisive if: a forced mate (any sign, incl. mate 0 = side to move is
        already mated), or a CP advantage >= ADJUDICATE_CP. Terminal
        positions (bestmove (none)) are resolved as checkmate if the side to
        move is in check, else stalemate (draw). The result is mapped to the
        white-perspective result string using the FEN side-to-move.
        """
        self._pos(moves)
        # Read the `d` diagram: it prints the board, then "Fen:", "Key:", and
        # "Checkers:" (empty string when not in check). Ends after Checkers.
        self._send("d")
        stm = "w"
        in_check = False
        while True:
            line = self._readline()
            if line.startswith("Fen:"):
                stm = line.split()[2]  # "w"/"b" (3rd whitespace field)
            elif line.startswith("Checkers:"):
                in_check = line[len("Checkers:"):].strip() != ""
                break  # Checkers is the last line of the `d` output
        self._send("go nodes %d" % ADJUDICATE_NODES)
        mate, cp, best = None, None, None
        while True:
            line = self._readline()
            if line.startswith("info depth"):
                if " mate " in line:
                    mate = int(line.split(" mate ")[1].split()[0])
                parts = line.split()
                if " cp " in parts:
                    cp = int(parts[parts.index(" cp ") + 1])
            elif line.startswith("bestmove"):
                best = line.split()[1] if len(line.split()) > 1 else "(none)"
                break
        # Terminal: bestmove (none) => no legal move for the side to move.
        if best == "(none)":
            return ("1/2-1/2" if not in_check else
                    ("0-1" if stm == "w" else "1-0"))
        if mate is not None:
            winner = "w" if mate > 0 else "b"
        elif cp is not None and abs(cp) >= ADJUDICATE_CP:
            winner = "w" if cp > 0 else "b"
        else:
            return "1/2-1/2"
        return "1-0" if winner == "w" else "0-1"

    def close(self):
        self._send("quit")
        self.proc.wait(timeout=5)


# --- game loop ---------------------------------------------------------------

def play_game(sf, bridge, fen, plies, sf_color):
    """Play one game from `fen`. `sf_color` is 'w' or 'b' (the side Stockfish
    plays). Returns (result, ply_count, sunfish_last_score).

    Position sync: before each sunfish move, the bridge rebuilds sunfish's
    position from the current real-board FEN (via Stockfish's `d` output).
    This avoids all frame-conversion bookkeeping — the FEN is the ground
    truth and pos_from_fen handles the engine's rotation convention."""
    moves = []
    turn = 'w' if fen.split()[1] == 'w' else 'b'
    last_score = 0
    for ply in range(plies):
        if turn == sf_color:
            m = sf.bestmove(moves)
            if m == "(none)":
                # Stockfish has no legal move: mate or stalemate
                return sf.adjudicate(moves), ply, last_score
            moves.append(m)
        else:
            # sync sunfish to the real position, then let it move
            bridge.set_fen(sf.fen(moves))
            m, last_score = bridge.ai_move()
            if m is None:
                # sunfish passes (decided): adjudicate the current position
                return sf.adjudicate(moves), ply, last_score
            moves.append(m)
        turn = 'b' if turn == 'w' else 'w'
    # Ply cap reached: adjudicate the final position rather than assume a draw
    return sf.adjudicate(moves), plies, last_score


# --- Elo estimation ----------------------------------------------------------

def fit_elo(results):
    """Maximum-likelihood fit of sunfish Elo vs the anchor curve.

    results: list of (nodes, wins, draws, losses) vs Stockfish. Each game's
    expected score for sunfish is the logistic Elo formula
      E = 1 / (1 + 10^(-(R_sf - R_stockfish)/400))
    with R_stockfish from sf_elo_anchor(nodes). Returns the fitted R_sf
    maximizing the binomial log-likelihood (golden-section search).
    """
    def neg_ll(r_sf):
        ll = 0.0
        for nodes, w, d, l in results:
            n = w + d + l
            if n == 0:
                continue
            e = 1.0 / (1.0 + 10 ** (-(r_sf - sf_elo_anchor(nodes)) / 400.0))
            # 3-outcome model: p_win = E^2-ish; use the standard expectation
            # of score (1 for win, .5 for draw, 0 for loss) as the Bernoulli p.
            scored = (w + 0.5 * d) / n
            ll += n * (scored * math.log(e) + (1 - scored) * math.log(1 - e)) if 0 < e < 1 else 0.0
        return -ll

    lo, hi = 0.0, 4000.0
    for _ in range(80):
        m1 = lo + (hi - lo) / 3
        m2 = hi - (hi - lo) / 3
        if neg_ll(m1) < neg_ll(m2):
            hi = m2
        else:
            lo = m1
    return (lo + hi) / 2, neg_ll((lo + hi) / 2)


def main():
    ap = argparse.ArgumentParser(description="Estimate sunfish Elo vs Stockfish")
    ap.add_argument("--engine", default=os.getcwd())
    ap.add_argument("--stockfish",
                    default=".reference/stockfish/stockfish-ubuntu-x86-64-avx2")
    ap.add_argument("--games", type=int, default=1,
                    help="games per (level, opening); deterministic opponent "
                         "+ fixed book => 1 per opening is enough")
    ap.add_argument("--plies", type=int, default=60)
    ap.add_argument("--nodes",
                    default="20,50,100,300,1000,3000,10000,30000")
    ap.add_argument("--book", default=None)
    ap.add_argument("--adj-nodes", type=int, default=32000,
                    help="node budget for the per-game adjudication probe; spots "
                         "forced mates and >=800cp advantages (default 32000)")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    sf_path = args.stockfish
    if not os.path.isabs(sf_path):
        sf_path = os.path.join(os.getcwd(), sf_path)
    if not os.path.exists(sf_path):
        print(f"stockfish not found: {sf_path}", file=sys.stderr)
        return 1

    global ADJUDICATE_NODES
    ADJUDICATE_NODES = args.adj_nodes

    node_levels = [int(x) for x in args.nodes.split(",")]
    book = DEFAULT_BOOK
    if args.book:
        with open(args.book) as f:
            book = [l.strip() for l in f if l.strip() and not l.startswith("#")]

    rng = random.Random(args.seed)
    combos = [(n, fen, color) for n in node_levels for fen in book for color in ("w", "b")]
    rng.shuffle(combos)

    results = {n: {"w": 0, "d": 0, "l": 0} for n in node_levels}
    played = 0
    total = len(combos) * args.games
    with tempfile.TemporaryDirectory(prefix="sunfish_bridge_") as tmpdir:
        bridge = SunfishBridge(args.engine, tmpdir)
        try:
            for nodes, fen, color in combos:
                for _ in range(args.games):
                    sf = Stockfish(sf_path, nodes, fen)
                    try:
                        res, ply, sc = play_game(sf, bridge, fen, args.plies, color)
                    finally:
                        sf.close()
                    r = results[nodes]
                    if res == "1-0":
                        r["w" if color == "w" else "l"] += 1
                    elif res == "0-1":
                        r["l" if color == "w" else "w"] += 1
                    else:
                        r["d"] += 1
                    played += 1
                    outcome = {"1-0": "1-0" if color == "w" else "0-1",
                               "0-1": "0-1" if color == "w" else "1-0",
                               "1/2-1/2": "1/2-1/2"}[res]
                    # outcome is white-perspective; color is sunfish's color.
                    sunfish_won = ((outcome == "1-0") == (color == "w")) and res != "1/2-1/2"
                    sf_won = (res != "1/2-1/2") and not sunfish_won
                    label = "SUNFISH" if sunfish_won else ("SF" if sf_won else "draw")
                    print("... game %d/%d  sf@%d  sunfish=%s  %s  [%s]"
                          % (played, total, nodes, color, outcome, label),
                          file=sys.stderr)
        finally:
            bridge.close()

    print("\n=== sunfish vs Stockfish 18 (node-limited) ===")
    print(f"{'nodes':>8} {'~sf_elo':>8} {'W':>4} {'D':>4} {'L':>4} "
          f"{'pts':>6} {'score':>7} {'sunfish~':>8}")
    fit_data = []
    for n in node_levels:
        r = results[n]
        w, d, l = r["w"], r["d"], r["l"]
        pts = w + d / 2
        games = w + d + l
        score = pts / games if games else 0
        elo = sf_elo_anchor(n) + 400 * math.log10(score / (1 - score)) if 0 < score < 1 else float("nan")
        print(f"{n:>8} {sf_elo_anchor(n):>8.0f} {w:>4} {d:>4} {l:>4} "
              f"{pts:>6.1f} {score:>7.3f} {elo:>8.0f}")
        fit_data.append((n, w, d, l))

    r_fit, _ = fit_elo(fit_data)
    print(f"\nFitted sunfish Elo (logistic ML, anchored on the ~sf_elo curve): "
          f"{r_fit:.0f}")


if __name__ == "__main__":
    sys.exit(main())
