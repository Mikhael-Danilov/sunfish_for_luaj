#!/usr/bin/env python3
"""Precompute full KRK/KQK DTM tables with an independent, fast retrograde
oracle using bitboards, and dump them for the validator.

The oracle mirrors bkm.lua's game graph exactly (capture of the strong piece =
draw, checkmate = DTM 0) but is implemented independently.

Output format (one line per state, 64*64*64*2 = 524288 lines):
  wk pc bk stm status dtm
  status: 1=WIN 2=DRAW 3=INVALID

Usage:
  python3 benchmarks/gen_bkm_oracle.py [outdir]
"""

import os
import sys

OUTDIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp/bkm_oracle"
N = 524288

# --- precompute bitboards -------------------------------------------------
KING_ATT = [0] * 64  # bitboard of squares attacked by a king on sq
PIECE_ATT = {}  # (piece, pc_sq, blocker_sq) -> bitboard of squares attacked
for sq in range(64):
    f, r = sq % 8, sq // 8
    bb = 0
    for df in (-1, 0, 1):
        for dr in (-1, 0, 1):
            if df == 0 and dr == 0:
                continue
            nf, nr = f + df, r + dr
            if 0 <= nf < 8 and 0 <= nr < 8:
                bb |= 1 << (nr * 8 + nf)
    KING_ATT[sq] = bb

_DIRS_R = [(1, 0), (-1, 0), (0, 1), (0, -1)]
_DIRS_Q = _DIRS_R + [(1, 1), (1, -1), (-1, 1), (-1, -1)]


def piece_attacks(piece, pc, blocker):
    key = (piece, pc, blocker)
    if key in PIECE_ATT:
        return PIECE_ATT[key]
    dirs = _DIRS_R if piece == "R" else _DIRS_Q
    bb = 0
    pf, pr = pc % 8, pc // 8
    for df, dr in dirs:
        f, r = pf + df, pr + dr
        while 0 <= f < 8 and 0 <= r < 8:
            s = r * 8 + f
            bb |= 1 << s
            if s == blocker:
                break
            f += df
            r += dr
    PIECE_ATT[key] = bb
    return bb


def kings_ok(a, b):
    return not (KING_ATT[a] >> b) & 1


def encode(wk, pc, bk, stm):
    return wk + pc * 64 + bk * 4096 + stm * 262144  # 0-based for arrays


def decode(idx):
    stm = idx // 262144
    x = idx % 262144
    bk = x // 4096
    x %= 4096
    pc = x // 64
    wk = x % 64
    return wk, pc, bk, stm


def build_oracle(piece):
    status = [0] * N  # 0 unknown, 1 win, 2 draw, 3 invalid
    dtm = [0] * N
    info = [0] * N
    buckets = {}
    win_count = draw_count = invalid_count = 0

    def enqueue(idx, d):
        nonlocal win_count
        status[idx] = 1
        dtm[idx] = d
        win_count += 1
        buckets.setdefault(d, []).append(idx)

    att_piece = {pc: [piece_attacks(piece, pc, wk) for wk in range(64)] for pc in range(64)}
    # weak king moves: square -> list of target squares
    weak_moves_of = {}
    for bk in range(64):
        lst = []
        bb = KING_ATT[bk]
        while bb:
            to = (bb & -bb).bit_length() - 1
            bb &= bb - 1
            lst.append(to)
        weak_moves_of[bk] = lst

    # init
    for stm in (0, 1):
        for bk in range(64):
            for pc in range(64):
                for wk in range(64):
                    idx = encode(wk, pc, bk, stm)
                    if (
                        wk == pc
                        or wk == bk
                        or pc == bk
                        or not kings_ok(wk, bk)
                        or (stm == 0 and (att_piece[pc][wk] >> bk) & 1)
                    ):
                        status[idx] = 3
                        invalid_count += 1
                    elif stm == 1:
                        # weak legal moves: king moves that are legal
                        cnt = 0
                        movebb = KING_ATT[bk]
                        # remove squares occupied by strong king
                        movebb &= ~(1 << wk)
                        # remove squares adjacent to the strong king (controlled)
                        movebb &= ~KING_ATT[wk]
                        # remove squares attacked by the piece (unless capture of pc)
                        atk = att_piece[pc][wk]
                        # capture of pc allowed iff pc not adjacent to wk
                        cap_ok = kings_ok(pc, wk)
                        tmp = movebb
                        while tmp:
                            to = (tmp & -tmp).bit_length() - 1
                            tmp &= tmp - 1
                            if to == pc:
                                if cap_ok:
                                    cnt += 1
                            elif not ((atk >> to) & 1):
                                cnt += 1
                        if cnt == 0:
                            if (att_piece[pc][wk] >> bk) & 1:
                                enqueue(idx, 0)
                            else:
                                status[idx] = 2
                                draw_count += 1
                        else:
                            info[idx] = cnt * 4096
                            status[idx] = 0
                    else:
                        status[idx] = 0

    # retrograde
    d = 0
    while buckets.get(d) is not None:
        for idx in list(buckets[d]):
            wk, pc, bk, stm = decode(idx)
            if stm == 1:
                # predecessor strong king moves: prev_wk adjacent to wk
                prevs = KING_ATT[wk]
                for pw in range(64):
                    if (prevs >> pw) & 1:
                        if pw != pc and pw != bk and kings_ok(pw, bk):
                            p = encode(pw, pc, bk, 0)
                            if status[p] == 0:
                                enqueue(p, d + 1)
                # predecessor strong piece moves: slides into current pc
                for df, dr in (_DIRS_R if piece == "R" else _DIRS_Q):
                    pf, pr = pc % 8, pc // 8
                    f, r = pf - df, pr - dr
                    while 0 <= f < 8 and 0 <= r < 8:
                        s = r * 8 + f
                        if s == wk or s == bk:
                            break
                        p = encode(wk, s, bk, 0)
                        if status[p] == 0:
                            enqueue(p, d + 1)
                        f -= df
                        r -= dr
            else:
                # predecessor weak king moves: prev_bk adjacent to bk
                prevs = KING_ATT[bk]
                for pb in range(64):
                    if (prevs >> pb) & 1:
                        if pb != wk and pb != pc and kings_ok(pb, wk):
                            p = encode(wk, pc, pb, 1)
                            if status[p] == 0:
                                c = info[p] // 4096
                                if c == 0:
                                    continue
                                s = (info[p] // 256) % 16
                                m = info[p] % 256
                                s += 1
                                if d > m:
                                    m = d
                                if s == c:
                                    enqueue(p, m + 1)
                                else:
                                    info[p] = c * 4096 + s * 256 + m
        d += 1

    for i in range(N):
        if status[i] == 0:
            status[i] = 2
            draw_count += 1

    return status, dtm, (win_count, draw_count, invalid_count)


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    for piece in ("R", "Q"):
        status, dtm, (wc, dc, ic) = build_oracle(piece)
        # binary: for each of 524288 states, 1 byte status + 1 byte dtm
        path = os.path.join(OUTDIR, f"oracle_{piece}.bin")
        buf = bytearray(2 * 524288)
        for idx in range(524288):
            buf[2 * idx] = status[idx]
            buf[2 * idx + 1] = dtm[idx]
        with open(path, "wb") as f:
            f.write(buf)
        print(f"[{piece}] {wc} wins, {dc} draws, {ic} invalid -> {path}")


if __name__ == "__main__":
    main()
