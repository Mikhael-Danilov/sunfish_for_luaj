#!/usr/bin/env python3
"""Full-table comparison of bkm.lua's KRK/KQK DTM tables against precomputed
oracle tables (from gen_bkm_oracle.py).

Dumps the entire 524288-state table from the Lua solver and diffs status and
DTM byte-for-byte against the oracle. This is an exhaustive validation, not a
sample.

The oracle encodes the same game graph as bkm.lua (capture of the strong piece
by the weak king = immediate draw; checkmate = DTM 0).

Usage:
  python3 benchmarks/validate_bkm.py [lua] [oracle_dir]

Requires python-chess (for square names only in error output).
"""

import os
import subprocess
import sys

import chess

LUA = sys.argv[1] if len(sys.argv) > 1 else "luajit"
ORACLE_DIR = sys.argv[2] if len(sys.argv) > 2 else "/tmp/bkm_oracle"

LUA_PROBE = r"""
local bkm = require("bkm")
local piece = os.getenv("BKM_PIECE")
local sol = bkm.solver(piece)
local out = {}
local n = 524288
for i = 1, n do
  -- decode to (wk,pc,bk,stm) then use evaluate() to read status+dtm
  local wk, pc, bk, stm = sol.decode(i)
  local st, dd = sol:evaluate(wk, pc, bk, stm)
  out[i] = string.format("%d,%d", st, dd or 0)
end
io.write(table.concat(out, "\n"))
"""


def sq(s):
    return chess.SQUARE_NAMES[s]


def load_oracle(piece):
    with open(f"{ORACLE_DIR}/oracle_{piece}.bin", "rb") as f:
        return f.read()


def main():
    for piece in ("R", "Q"):
        data = load_oracle(piece)
        env = dict(os.environ, BKM_PIECE=piece)
        proc = subprocess.run(
            [LUA, "-e", LUA_PROBE], capture_output=True, text=True, env=env
        )
        if proc.returncode != 0:
            print(f"[{piece}] lua probe failed: {proc.stderr}")
            sys.exit(1)
        lines = proc.stdout.strip().splitlines()
        mism = 0
        invalid_both = 0
        win_checked = 0
        examples = []
        for i, line in enumerate(lines):
            st, dd = map(int, line.split(","))
            ost = data[2 * i]
            odtm = data[2 * i + 1]
            if ost == 3:
                if st == 3:
                    invalid_both += 1
                else:
                    mism += 1
                    if len(examples) < 15:
                        examples.append(f"lua says {st}, oracle says invalid (idx {i})")
                continue
            if ost == 1:
                win_checked += 1
                if st != 1 or dd != odtm:
                    mism += 1
                    if len(examples) < 15:
                        x = i - 1
                        stm = x // 262144
                        x %= 262144
                        bk = x // 4096
                        x %= 4096
                        pc = x // 64
                        wk = x % 64
                        examples.append(
                            f"idx {i} wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm}: "
                            f"lua={st}/{dd} oracle=WIN/{odtm}"
                        )
            else:  # oracle draw
                if st != 2:
                    mism += 1
                    if len(examples) < 15:
                        x = i - 1
                        stm = x // 262144
                        x %= 262144
                        bk = x // 4096
                        x %= 4096
                        pc = x // 64
                        wk = x % 64
                        examples.append(
                            f"idx {i} wk={sq(wk)} pc={sq(pc)} bk={sq(bk)} stm={stm}: "
                            f"lua={st}/{dd} oracle=DRAW"
                        )
        print(
            f"[{piece}] full-table diff: {win_checked} oracle-wins, "
            f"{invalid_both} both-invalid, {mism} mismatches"
        )
        for e in examples:
            print("  " + e)
        if mism:
            sys.exit(1)


if __name__ == "__main__":
    main()
