"""alpha-zero-general `Game` adapter for Drott, over the parity-proven rules in
drott_rules.py.

Board representation (the array the framework passes around)
-----------------------------------------------------------
A 9x9 int8 grid, absolute frame, indexed `grid[row, col]`:
    0        empty
   +code     a RED piece   (code = 1..9, see drott_rules.TYPE_CODE)
   -code     a BLACK piece
Side-to-move is NOT stored in the grid — the framework tracks it via `player`
(+1 = red, -1 = black), exactly as Othello tracks it separately from its grid.

Action encoding
---------------
A move is (from_square, to_square); squares are `idx = col + row*9` (matching the
Swift engine). The flat action is:
    action = from_idx * 81 + to_idx          # 81*81 = 6561 actions
~98% are always illegal and are masked every step by getValidMoves.

Canonical form (the key design choice, see ALPHAZERO_PLAN.md §2.3)
-----------------------------------------------------------------
Drott's start is point-symmetric, so the canonical form for black is a 180°
rotation + side swap: `canon = -rot180(grid)`. After it, the side to move is
always shown as +code moving "up" the board, so the net only learns one POV.

Because the canonical transform PERMUTES squares (unlike Othello's colour-only
flip), an action chosen in canonical space means a different physical move in the
real frame. The Coach/Arena loops sample the action on the canonical board but
call getNextState with the REAL board + REAL player — so getNextState rotates the
action back by 180° when player == -1. (Inside MCTS, getNextState is only ever
called with player == 1, so no remap happens there.) test_game.py proves this
whole scheme stays in lockstep with drott_rules across thousands of plies.
"""

from __future__ import annotations

import os
import sys

import numpy as np

import drott_rules
from drott_rules import Board as RulesBoard, N, TYPE_CODE

# Subclass the framework's Game when it is importable; fall back to `object` so
# this module can be imported and unit-tested without the framework on the path.
_AZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "alpha-zero-general-master")
if _AZ not in sys.path:
    sys.path.insert(0, _AZ)
try:
    from Game import Game as _Game
except Exception:  # pragma: no cover - framework not present
    _Game = object

CODE_TYPE = {code: name for name, code in TYPE_CODE.items()}
ACTION_SIZE = (N * N) * (N * N)   # 6561

# Start position, mirroring Board.setupStart() in Models.swift. (col, row, type, side)
START_PIECES = [
    (1, 0, "skjolding", "red"), (2, 0, "wolf", "red"), (3, 0, "elf", "red"),
    (4, 0, "king", "red"), (5, 0, "dwarf", "red"), (6, 0, "hunter", "red"),
    (7, 0, "skjolding", "red"), (2, 1, "skjolding", "red"), (3, 1, "berserker", "red"),
    (4, 1, "spearman", "red"), (5, 1, "bowman", "red"), (6, 1, "skjolding", "red"),
    (3, 2, "skjolding", "red"), (4, 2, "skjolding", "red"), (5, 2, "skjolding", "red"),
    (7, 8, "skjolding", "black"), (6, 8, "wolf", "black"), (5, 8, "elf", "black"),
    (4, 8, "king", "black"), (3, 8, "dwarf", "black"), (2, 8, "hunter", "black"),
    (1, 8, "skjolding", "black"), (6, 7, "skjolding", "black"), (5, 7, "berserker", "black"),
    (4, 7, "spearman", "black"), (3, 7, "bowman", "black"), (2, 7, "skjolding", "black"),
    (5, 6, "skjolding", "black"), (4, 6, "skjolding", "black"), (3, 6, "skjolding", "black"),
]


# -- action <-> (from, to) helpers ------------------------------------------

def square_to_idx(col, row):
    return col + row * N


def idx_to_square(idx):
    return (idx % N, idx // N)   # (col, row)


def encode_action(frm, to):
    return square_to_idx(*frm) * (N * N) + square_to_idx(*to)


def decode_action(action):
    f, t = divmod(action, N * N)
    return idx_to_square(f), idx_to_square(t)


def rot180_action(action):
    """The same physical move under a 180° board rotation. Square idx -> 80-idx,
    so from/to each map idx -> 80-idx."""
    f, t = divmod(action, N * N)
    return (80 - f) * (N * N) + (80 - t)


# -- grid <-> RulesBoard -----------------------------------------------------

def grid_to_board(grid, side_to_move):
    """Absolute-frame grid -> a drott_rules.Board (winner=None)."""
    squares = [None] * (N * N)
    for row in range(N):
        for col in range(N):
            v = int(grid[row, col])
            if v == 0:
                continue
            side = "red" if v > 0 else "black"
            squares[col + row * N] = (CODE_TYPE[abs(v)], side, col, row)
    return RulesBoard(squares, side_to_move, None, None)


def board_to_grid(board):
    grid = np.zeros((N, N), dtype=np.int8)
    for sq in board.squares:
        if sq is None:
            continue
        ptype, side, col, row = sq
        code = TYPE_CODE[ptype]
        grid[row, col] = code if side == "red" else -code
    return grid


def _side_of(player):
    return "red" if player == 1 else "black"


class DrottGame(_Game):
    """Two-player adapter. player +1 = Red (moves up), -1 = Black (moves down)."""

    def getInitBoard(self):
        b = RulesBoard.from_pieces(
            [(c, r, t, s) for (c, r, t, s) in START_PIECES], "red")
        return board_to_grid(b)

    def getBoardSize(self):
        return (N, N)

    def getActionSize(self):
        return ACTION_SIZE

    def getNextState(self, board, player, action):
        # In Coach/Arena the action was chosen on the canonical board but `board`
        # here is the real frame; for black, rotate the action back 180°.
        if player == -1:
            action = rot180_action(action)
        b = grid_to_board(board, _side_of(player))
        frm, to = decode_action(action)
        is_cap = b.piece_at(*to) is not None
        nb = b.applying((frm, to, is_cap))
        return board_to_grid(nb), -player

    def getValidMoves(self, board, player):
        b = grid_to_board(board, _side_of(player))
        valids = np.zeros(ACTION_SIZE, dtype=np.int8)
        for frm, to, _cap in b.legal_moves():
            valids[encode_action(frm, to)] = 1
        return valids

    def getGameEnded(self, board, player):
        side = _side_of(player)
        b = grid_to_board(board, side)
        winner, _reason = b.static_outcome()
        if winner is not None:
            return 1.0 if winner == side else -1.0
        # No standing win, but if the side to move has no move it is lost.
        if not b.legal_moves():
            return -1.0
        return 0.0

    def getCanonicalForm(self, board, player):
        if player == 1:
            return board
        # 180° rotation + colour swap: the side to move becomes +code moving up.
        return -np.rot90(board, 2)

    def getSymmetries(self, board, pi):
        # Identity only for now. The LR-mirror (forts + castle are LR-symmetric)
        # is a valid 2x augmentation but is deferred until proven against the
        # parity oracle (ALPHAZERO_PLAN.md §2.4).
        return [(board, pi)]

    def stringRepresentation(self, board):
        return board.tobytes()

    @staticmethod
    def display(board):
        sym = {0: "."}
        for name, code in TYPE_CODE.items():
            sym[code] = name[0].upper()
            sym[-code] = name[0].lower()
        print("   " + " ".join("ABCDEFGHI"))
        for row in range(N - 1, -1, -1):
            cells = " ".join(sym[int(board[row, col])] for col in range(N))
            print(f"{row + 1:2} {cells}")
