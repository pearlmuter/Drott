"""Faithful, dependency-free port of Drott's rules from Sources/Drott/Models.swift.

This is the Python side of the parity oracle (ALPHAZERO_PLAN.md §3.1). It must
reproduce the Swift engine's legal moves, transitions, win conditions, and
position hash EXACTLY — test_parity.py checks it against the golden corpus dumped
by Corpus.swift. No neural-net work begins until parity is green.

Conventions mirror Models.swift:
  - The board is 9x9, indexed `col + row*N`.
  - Red moves "up" the board (row increases, fwd = +1); Black moves "down".
  - A piece is the immutable tuple (type:str, side:str, col:int, row:int). Using
    a value type (never mutated in place) makes `applying` copy-safe by design,
    matching Swift's `struct Piece`.
"""

from __future__ import annotations

N = 9

# Piece type -> compact 1..9 code, matching PieceType.code in Models.swift. The
# code feeds the FNV-1a position hash, so it must match byte-for-byte.
TYPE_CODE = {
    "king": 1, "berserker": 2, "spearman": 3, "bowman": 4, "elf": 5,
    "wolf": 6, "dwarf": 7, "hunter": 8, "skjolding": 9,
}

CASTLE = (4, 4)  # Position.castle for N=9

RED_FORT = frozenset({
    (2, 0), (3, 0), (4, 0), (5, 0), (6, 0),
    (3, 1), (4, 1), (5, 1),
})
BLACK_FORT = frozenset({
    (2, 8), (3, 8), (4, 8), (5, 8), (6, 8),
    (3, 7), (4, 7), (5, 7),
})

KNIGHT_OFFSETS = [(2, 1), (2, -1), (-2, 1), (-2, -1),
                  (1, 2), (1, -2), (-1, 2), (-1, -2)]

_MASK64 = (1 << 64) - 1


def other(side: str) -> str:
    return "black" if side == "red" else "red"


def in_bounds(col: int, row: int) -> bool:
    return 0 <= col < N and 0 <= row < N


def is_fort(col: int, row: int, for_side: str) -> bool:
    """True if (col,row) is `for_side`'s own fort square."""
    return (col, row) in (RED_FORT if for_side == "red" else BLACK_FORT)


class Board:
    """Pure value-style game state: occupancy + side to move + (winner, reason)."""

    __slots__ = ("squares", "side_to_move", "winner", "win_reason")

    def __init__(self, squares=None, side_to_move="red", winner=None, win_reason=None):
        # squares: list length N*N of None | (type, side, col, row)
        self.squares = squares if squares is not None else [None] * (N * N)
        self.side_to_move = side_to_move
        self.winner = winner
        self.win_reason = win_reason

    # -- construction --------------------------------------------------------

    @classmethod
    def from_pieces(cls, pieces, side_to_move):
        """Build a live (winner=None) board from a list of (col,row,type,side)."""
        sq = [None] * (N * N)
        for col, row, ptype, side in pieces:
            sq[col + row * N] = (ptype, side, col, row)
        return cls(sq, side_to_move, None, None)

    def copy(self) -> "Board":
        return Board(list(self.squares), self.side_to_move, self.winner, self.win_reason)

    # -- access --------------------------------------------------------------

    def piece_at(self, col: int, row: int):
        if not in_bounds(col, row):
            return None
        return self.squares[col + row * N]

    def occupied(self, col: int, row: int) -> bool:
        if not in_bounds(col, row):
            return False
        return self.squares[col + row * N] is not None

    def king_position(self, side: str):
        for sq in self.squares:
            if sq is not None and sq[0] == "king" and sq[1] == side:
                return (sq[2], sq[3])
        return None

    # -- position hash (FNV-1a; must match Board.repetitionKey) ---------------

    def repetition_key(self) -> int:
        h = 14695981039346656037
        for sq in self.squares:
            if sq is not None:
                b = (0 if sq[1] == "red" else 100) + TYPE_CODE[sq[0]]
            else:
                b = 0
            h = ((h ^ b) * 1099511628211) & _MASK64
        h = ((h ^ (201 if self.side_to_move == "red" else 202)) * 1099511628211) & _MASK64
        return h

    # -- move generation -----------------------------------------------------

    def legal_moves(self):
        """All pseudo-legal moves for the side to move, as (from, to, is_capture)
        where from/to are (col,row). Mirrors Board.legalMoves()."""
        result = []
        for sq in self.squares:
            if sq is None or sq[1] != self.side_to_move:
                continue
            self._generate(sq, result)
        return result

    def _generate(self, p, out):
        ptype = p[0]
        gen = _GENERATORS[ptype]
        gen(self, p, out)

    # -- apply ---------------------------------------------------------------

    def applying(self, move) -> "Board":
        frm, to, _is_cap = move
        b = self.copy()
        b.win_reason = None
        from_idx = frm[0] + frm[1] * N
        to_idx = to[0] + to[1] * N
        mover = b.squares[from_idx]
        if mover is None:
            return b
        mover_side = mover[1]

        captured = b.squares[to_idx]
        if captured is not None and captured[0] == "king":
            b.winner = mover_side
            b.win_reason = "kingCapture"

        # Relocate the mover (new immutable tuple at the destination).
        b.squares[to_idx] = (mover[0], mover[1], to[0], to[1])
        b.squares[from_idx] = None

        # The opponent's turn begins.
        b.side_to_move = other(mover_side)

        if b.winner is not None:  # king capture already decided it
            return b

        claimant = b.side_to_move
        if b.king_position(claimant) == CASTLE:
            b.winner = claimant
            b.win_reason = "castle"
        elif b.has_fort_control(claimant):
            b.winner = claimant
            b.win_reason = "fort"
        return b

    def static_outcome(self):
        """Win/loss as a PURE function of (occupancy, side_to_move) — no move
        history. For a board produced by `applying` (side already switched), this
        equals the (winner, win_reason) that `applying` itself computed. That
        equivalence (proven over the whole corpus in test_parity.py) is what lets
        the alpha-zero-general adapter implement `getGameEnded` statically, even
        though Drott's castle/fort wins read as "survive to your next turn":
        surviving IS encoded by it being your turn again with the claim intact.

        Returns (winner, reason) or (None, None) for an ongoing position.
        """
        stm = self.side_to_move
        # Your king is gone -> it was captured last move -> the opponent won.
        if self.king_position(stm) is None:
            return (other(stm), "kingCapture")
        # It is your turn with your king on the castle / holding the enemy fort:
        # the claim you set up survived the opponent's reply.
        if self.king_position(stm) == CASTLE:
            return (stm, "castle")
        if self.has_fort_control(stm):
            return (stm, "fort")
        return (None, None)

    def has_fort_control(self, side: str) -> bool:
        opp = other(side)
        in_opp = False
        opp_defends = False
        for sq in self.squares:
            if sq is None:
                continue
            ptype, pside, col, row = sq
            if pside == side and is_fort(col, row, opp):
                in_opp = True
            if pside == opp and is_fort(col, row, opp):
                opp_defends = True
        return in_opp and not opp_defends


# ---------------------------------------------------------------------------
# Per-piece movement generators. Each appends (from, to, is_capture) to `out`.
# They mirror the private *Moves functions in Models.swift one-for-one.
# ---------------------------------------------------------------------------

def _fwd(side: str) -> int:
    return 1 if side == "red" else -1


def _emit(board, p, out, col, row):
    """Void-form `add`: emit a move/capture if the square is on-board and not a
    friendly piece. (Used by skjolding, king, hunter.)"""
    if not in_bounds(col, row):
        return
    frm = (p[2], p[3])
    hit = board.squares[col + row * N]
    if hit is not None:
        if hit[1] != p[1]:
            out.append((frm, (col, row), True))
    else:
        out.append((frm, (col, row), False))


def _emit_ret(board, p, out, col, row) -> bool:
    """Bool-form `add`: like _emit, but returns True only when the square was
    empty (so a slide can continue). Mirrors the `-> Bool` add closures."""
    if not in_bounds(col, row):
        return False
    frm = (p[2], p[3])
    hit = board.squares[col + row * N]
    if hit is not None:
        if hit[1] != p[1]:
            out.append((frm, (col, row), True))
        return False
    out.append((frm, (col, row), False))
    return True


def _knight_blocked(board, c, r, dc, dr) -> bool:
    sc = 1 if dc > 0 else -1
    sr = 1 if dr > 0 else -1
    horiz = abs(dc) > abs(dr)
    a = board.occupied(c + sc if horiz else c, r if horiz else r + sr)
    b = board.occupied(c + sc, r + sr)
    cc = board.occupied(c if horiz else c + sc, r + sr if horiz else r)
    u = board.occupied(c + 2 * sc if horiz else c, r if horiz else r + 2 * sr)
    return (a and b) or (a and cc) or (b and u)


def _narrow_leap_clear(board, c, r, side, fwd, dist) -> bool:
    for j in range(0, dist + 1):
        clear = True
        k = 1
        while k <= j:
            if board.occupied(c, r + k * fwd):
                clear = False
                break
            k += 1
        if not clear:
            continue
        k = j
        while k <= dist - 1:
            if board.occupied(c + side, r + k * fwd):
                clear = False
                break
            k += 1
        if clear:
            return True
    return False


def _skjolding(board, p, out):
    fwd = _fwd(p[1])
    c, r = p[2], p[3]
    if not board.occupied(c, r + fwd):
        _emit(board, p, out, c, r + 2 * fwd)
    for dc in (-1, 1):
        if board.occupied(c, r + fwd) and board.occupied(c + dc, r):
            continue
        _emit(board, p, out, c + dc, r + fwd)
    _emit(board, p, out, c, r - fwd)


def _berserker(board, p, out):
    fwd = _fwd(p[1])
    c, r = p[2], p[3]
    # straight ahead is a slide
    for step in (1, 2, 3):
        if not _emit_ret(board, p, out, c, r + step * fwd):
            break
    # forward-diagonal columns are leaps gated by line-of-sight
    for dc in (-1, 1):
        for step in (1, 2, 3):
            if not _narrow_leap_clear(board, c, r, dc, fwd, step):
                continue
            _emit_ret(board, p, out, c + dc, r + step * fwd)
    for dc in (-1, 1):
        _emit_ret(board, p, out, c + dc, r)


def _spearman(board, p, out):
    fwd = _fwd(p[1])
    c, r = p[2], p[3]
    center_clear = _emit_ret(board, p, out, c, r + fwd)
    if board.occupied(c, r + fwd) and board.occupied(c - 1, r):
        left_clear = False
    else:
        left_clear = _emit_ret(board, p, out, c - 1, r + fwd)
    if board.occupied(c, r + fwd) and board.occupied(c + 1, r):
        right_clear = False
    else:
        right_clear = _emit_ret(board, p, out, c + 1, r + fwd)

    if center_clear:
        _emit_ret(board, p, out, c, r + 2 * fwd)
    if left_clear and not (board.occupied(c - 1, r + 2 * fwd) and board.occupied(c - 2, r + fwd)):
        _emit_ret(board, p, out, c - 2, r + 2 * fwd)
    if right_clear and not (board.occupied(c + 1, r + 2 * fwd) and board.occupied(c + 2, r + fwd)):
        _emit_ret(board, p, out, c + 2, r + 2 * fwd)
    _emit_ret(board, p, out, c, r - fwd)


def _wolf(board, p, out):
    c, r = p[2], p[3]
    frm = (c, r)
    for dc, dr in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        col, row = c + dc, r + dr
        for _ in range(3):
            if not in_bounds(col, row):
                break
            hit = board.squares[col + row * N]
            if hit is not None:
                if hit[1] != p[1]:
                    out.append((frm, (col, row), True))
                break
            out.append((frm, (col, row), False))
            col += dc
            row += dr


def _elf(board, p, out):
    c, r = p[2], p[3]
    for dc, dr in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        _emit_ret(board, p, out, c + dc, r + dr)
    for dc, dr in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        col, row = c + dc, r + dr
        for _ in range(4):
            # shieldwall: a diagonal step cannot slip between two pieces standing
            # orthogonally on either side of it.
            if board.occupied(col, row - dr) and board.occupied(col - dc, row):
                break
            if not _emit_ret(board, p, out, col, row):
                break
            col += dc
            row += dr


def _king(board, p, out):
    c, r = p[2], p[3]
    # Orthogonal steps are unconditional.
    for dc, dr in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        _emit(board, p, out, c + dc, r + dr)
    # Diagonal steps are blocked by a shield wall: the king may not slip
    # between two pieces on the orthogonal corners of the diagonal (matches JS
    # _king in drott-rules.js and the _dwarf/_hunter origin-corner pinch).
    for dc, dr in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        if board.occupied(c, r + dr) and board.occupied(c + dc, r):
            continue  # origin-corner pinch
        _emit(board, p, out, c + dc, r + dr)


def _dwarf(board, p, out):
    c, r = p[2], p[3]
    for dc, dr in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        for step in (1, 2):
            if not _emit_ret(board, p, out, c + dc * step, r + dr * step):
                break
    for dc, dr in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        if board.occupied(c, r + dr) and board.occupied(c + dc, r):
            continue  # origin-corner pinch
        if board.occupied(c + dc, r + dr):
            continue  # midpoint on the line
        if board.occupied(c + dc, r + 2 * dr) and board.occupied(c + 2 * dc, r + dr):
            continue  # target-corner pinch
        _emit_ret(board, p, out, c + dc * 2, r + dr * 2)
    for dc, dr in KNIGHT_OFFSETS:
        if _knight_blocked(board, c, r, dc, dr):
            continue
        _emit_ret(board, p, out, c + dc, r + dr)


def _hunter(board, p, out):
    c, r = p[2], p[3]
    for dc, dr in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        if board.occupied(c, r + dr) and board.occupied(c + dc, r):
            continue
        _emit(board, p, out, c + dc, r + dr)
    for dc, dr in KNIGHT_OFFSETS:
        if _knight_blocked(board, c, r, dc, dr):
            continue
        _emit(board, p, out, c + dc, r + dr)


def _bowman(board, p, out):
    fwd = _fwd(p[1])
    c, r = p[2], p[3]
    for step in (1, 2, 3, 4):
        if not _emit_ret(board, p, out, c, r + step * fwd):
            break
    for dc in (-1, 1):
        _emit_ret(board, p, out, c + dc, r)


_GENERATORS = {
    "skjolding": _skjolding,
    "berserker": _berserker,
    "spearman": _spearman,
    "wolf": _wolf,
    "elf": _elf,
    "king": _king,
    "dwarf": _dwarf,
    "hunter": _hunter,
    "bowman": _bowman,
}
