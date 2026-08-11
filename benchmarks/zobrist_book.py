#!/usr/bin/env python3
"""Shared Zobrist book support for the sunfish Elo harness.

Replicates the exact 32-bit Zobrist key that sunfish.lua computes in
`Position:key()` (MWC PRNG + summation, board + castling + ep + kp terms),
so a book keyed by these hashes works with the engine's real position keys.
"""

import struct

# --- MWC PRNG (matches sunfish.lua's deterministic table seeding) ------------

def _mwc_table():
    """Return the 13 piece-square tables + wc/bc/ep/kp randoms, in the exact
    order sunfish.lua consumes them (0-based sq 0..119).

    sunfish.lua runs on LuaJIT/Lua 5.1 doubles, so the seed constant
    88172645463325252 is rounded to the nearest double (88172645463325248)
    before the % and / are applied. We replicate that float64 rounding with
    math.fmod + float division so the stream matches the engine bit-for-bit.
    """
    import math
    seed = float(88172645463325252)
    x = math.fmod(seed, 65536.0)
    c = math.floor(seed / 65536.0) % 65536
    out = []

    def rnd():
        nonlocal x, c
        t = x * 65539 + c
        c = math.floor(t / 65536.0) % 65536
        x = math.fmod(t, 65536.0)
        return int(x + c * 65536)

    # zob[pc][sq] for pc in -6..6, sq 0..119; engine stores zflat[(pc+6)*120+sq+1]
    zflat = {}
    for pc in range(-6, 7):
        for sq in range(120):
            zflat[(pc + 6) * 120 + sq + 1] = rnd()
    zob_wc = [rnd(), rnd()]
    zob_bc = [rnd(), rnd()]
    zob_ep = [0] * 121
    for sq in range(120):
        zob_ep[sq + 1] = rnd()
    zob_ep[121 - 1] = 0  # mirror of no-ep sentinel (index 120 in 0-based = sq 120)
    zob_kp = [0] * 121
    zob_kp[1 - 1] = 0
    for sq in range(1, 120):
        zob_kp[sq + 1] = rnd()
    zob_kp[121 - 1] = 0  # mirror of no-kp sentinel (index 120)
    return zflat, zob_wc, zob_bc, zob_ep, zob_kp


# --- FEN -> engine 120-char board (port of the bridge / test_perft) ---------

# piece char -> engine code (P=1, N=2, B=3, R=4, Q=5, K=6), negative for black
_PC = {"P": 1, "N": 2, "B": 3, "R": 4, "Q": 5, "K": 6}
_EMPTY, _SP, _NL = 0, 98, 99


def board_from_fen(fen_board, side):
    """120-char engine board (side to move uppercase at the bottom), exactly
    matching the bridge's board_from_fen and tests/test_perft.lua.

    Engine layout (1-based rows in the 120-char string):
      rows 1-2: top sentinel, row 3 = rank 8 ... row 10 = rank 1,
      row 11: bottom sentinel, row 12: "          " (10 spaces).
    """
    rows = {}
    for r in range(1, 13):
        if r in (1, 2, 11):
            rows[r] = "         \n"
        else:
            rows[r] = None
    rows[12] = "          "
    fen_rows = [p for p in fen_board.split("/")]
    # fen_rows[0] = rank 8 ... [7] = rank 1
    for fi, part in enumerate(fen_rows):
        rank = 8 - fi  # fi=0 -> rank 8 ... fi=7 -> rank 1 (engine iPairs is 1-based: rank = 9-fi)
        # engine 1-based string row: rank 8 -> 3, rank 1 -> 10
        row_idx = (10 - rank) + 1
        chars = [" "]
        col = 1
        for ch in part:
            if ch.isdigit():
                for _ in range(int(ch)):
                    chars.append(".")
                    col += 1
            else:
                chars.append(ch)
                col += 1
        chars.append("\n")
        rows[row_idx] = "".join(chars)
    out = []
    for r in range(1, 13):
        if rows[r] is None:
            rows[r] = "         \n"
        out.append(rows[r])
    board = "".join(out)
    if side == "b":
        flipped = []
        for ch in reversed(board):
            if "A" <= ch <= "Z":
                flipped.append(ch.lower())
            elif "a" <= ch <= "z":
                flipped.append(ch.upper())
            else:
                flipped.append(ch)
        board = "".join(flipped)
    return board


def board_to_codes(board):
    """120-char board -> list of 120 engine piece codes (signed)."""
    codes = []
    for ch in board:
        if ch == "." or ch in (" ", "\n"):
            codes.append(_EMPTY)
        elif ch == " ":
            codes.append(_EMPTY)
        elif ch.isupper():
            codes.append(_PC[ch])
        elif ch.islower():
            codes.append(-_PC[ch.upper()])
        else:
            codes.append(_SP)  # sentinel chars (unexpected); treat as non-piece
    return codes


def pos_from_fen(fen):
    """FEN -> (codes[120], wc, bc, ep, kp) in the engine's current frame."""
    parts = fen.split()
    board_field, side = parts[0], parts[1]
    castle = parts[2] if len(parts) > 2 else "-"
    ep = parts[3] if len(parts) > 3 else "-"
    board = board_from_fen(board_field, side)
    codes = board_to_codes(board)
    # castling: engine stores SIDE-TO-MOVE rights in wc, opponent in bc
    white = {"K": False, "Q": False}
    black = {"K": False, "Q": False}
    if castle and castle != "-":
        for ch in castle:
            if ch == "K":
                white["K"] = True
            elif ch == "Q":
                white["Q"] = True
            elif ch == "k":
                black["K"] = True
            elif ch == "q":
                black["Q"] = True
    if side == "b":
        wc = [black["K"], black["Q"]]
        bc = [white["K"], white["Q"]]
    else:
        wc = [white["K"], white["Q"]]
        bc = [black["K"], black["Q"]]
    # ep square -> engine index (0-based sentinel frame)
    ep_i = 0
    if ep and ep != "-":
        f = ord(ep[0]) - ord("a") + 1
        r = int(ep[1])
        ep_i = (10 - r) * 10 + f  # 0-based: row (10-r), col f
        if side == "b":
            ep_i = 119 - ep_i
    kp = 0
    return codes, wc, bc, ep_i, kp


def zobrist_key(codes, wc, bc, ep, kp, tables):
    """Engine `Position:key()`: (board_hash + flag_hash) mod 2^32."""
    zflat, zob_wc, zob_bc, zob_ep, zob_kp = tables
    bh = 0
    # engine iterates i = 1..120 (1-based) over the board string; zflat index is
    # (pc+6)*120 + sq where sq is 0-based. The board string is rows r=0..11 each
    # 10 chars (col 0..9); sq in the engine = (r*10 + c) 0-based.
    for idx, pc in enumerate(codes):
        if pc == _EMPTY or pc == _SP or pc == _NL:
            continue
        # engine uses 1-based i (1..120) as the square index into zflat
        bh += zflat[(pc + 6) * 120 + idx + 1]
    fh = 0
    if wc[0]:
        fh += zob_wc[0]
    if wc[1]:
        fh += zob_wc[1]
    if bc[0]:
        fh += zob_bc[0]
    if bc[1]:
        fh += zob_bc[1]
    if ep != 0:
        fh += zob_ep[ep]
    if kp != 0:
        fh += zob_kp[kp]
    return (bh + fh) % 4294967296


# --- Polyglot-style binary book format (hash64:move16) -----------------------
# 16 bytes/entry: 8-byte big-endian key, 2-byte move, 2-byte weight, 2-byte
# learn. We use a 32-bit key stored in the high 4 bytes (rest zero) for
# simplicity and keep the Polyglot field layout for familiarity.

def uci_to_poly(move):
    """'e2e4' -> 16-bit polyglot move (promo 0 = none).

    Promo uses the engine's piece codes (KN=2, B=3, R=4, Q=5) so a book move
    can be fed back to the engine's `sunfish.move` (5th char promotion)."""
    files = {c: i for i, c in enumerate("abcdefgh")}
    f1, r1, f2, r2 = move[0], int(move[1]), move[2], int(move[3])
    promo = {"n": 2, "b": 3, "r": 4, "q": 5}.get(move[4] if len(move) > 4 else "", 0)
    return (files[f1] << 6) | ((r1 - 1) << 3) | (files[f2]) | ((r2 - 1) << 9) | (promo << 12)


def poly_to_uci(move16):
    files = "abcdefgh"
    f1 = (move16 >> 6) & 7
    r1 = (move16 >> 3) & 7
    f2 = move16 & 7
    r2 = (move16 >> 9) & 7
    promo = (move16 >> 12) & 7
    m = f"{files[f1]}{r1+1}{files[f2]}{r2+1}"
    if promo:
        m += {2: "n", 3: "b", 4: "r", 5: "q"}[promo]
    return m


def book_write(entries, path):
    """entries: list of (key32, poly_move16, weight). Binary big-endian,
    16 bytes/entry: 8B key (key32 in high half), 2B move, 2B weight,
    2B learn(0), 2B pad(0)."""
    with open(path, "wb") as f:
        for key, mv, weight in entries:
            f.write(struct.pack(">QHHH", key << 32, mv, weight, 0))
            f.write(b"\x00\x00")  # pad to 16 bytes


def book_read(path):
    entries = []
    with open(path, "rb") as f:
        data = f.read()
    assert len(data) % 16 == 0, f"book size {len(data)} not a multiple of 16"
    for i in range(0, len(data), 16):
        key64, mv, weight, _ = struct.unpack_from(">QHHH", data, i)
        entries.append((key64 >> 32, mv, weight))
    return entries


TABLES = _mwc_table()
