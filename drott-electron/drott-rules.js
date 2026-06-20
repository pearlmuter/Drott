// drott-rules.js — faithful port of python/drott_rules.py
// Conventions mirror drott_rules.py exactly: col + row*N indexing, same FNV-1a.
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

const _N = 9;

const TYPE_CODE = {
  king: 1, berserker: 2, spearman: 3, bowman: 4, elf: 5,
  wolf: 6, dwarf: 7, hunter: 8, skjolding: 9,
};

const CASTLE = [4, 4]; // [col, row]

const RED_FORT = new Set([
  '2,0','3,0','4,0','5,0','6,0',
  '3,1','4,1','5,1',
]);
const BLACK_FORT = new Set([
  '2,8','3,8','4,8','5,8','6,8',
  '3,7','4,7','5,7',
]);

const KNIGHT_OFFSETS = [
  [2,1],[2,-1],[-2,1],[-2,-1],
  [1,2],[1,-2],[-1,2],[-1,-2],
];

// FNV-1a using BigInt to match the 64-bit Python/Swift hash exactly.
// Returns a BigInt. For Map keys we convert to string via .toString().
function repetitionKey(board) {
  let h = 14695981039346656037n;
  const mask = (1n << 64n) - 1n;
  for (const sq of board.squares) {
    let b;
    if (sq !== null) {
      b = BigInt((sq.side === 'red' ? 0 : 100) + TYPE_CODE[sq.type]);
    } else {
      b = 0n;
    }
    h = ((h ^ b) * 1099511628211n) & mask;
  }
  const stmByte = board.sideToMove === 'red' ? 201n : 202n;
  h = ((h ^ stmByte) * 1099511628211n) & mask;
  return h;
}

function otherSide(side) { return side === 'red' ? 'black' : 'red'; }
function inBounds(col, row) { return col >= 0 && col < _N && row >= 0 && row < _N; }
function isFort(col, row, forSide) {
  return forSide === 'red' ? RED_FORT.has(`${col},${row}`) : BLACK_FORT.has(`${col},${row}`);
}

// occupied: is square at (col,row) non-empty?
function occupied(squares, col, row) {
  if (!inBounds(col, row)) return false;
  return squares[col + row * _N] !== null;
}

// _emit: add a move if on-board and not a friendly piece (void form)
function _emit(squares, frm, side, out, col, row) {
  if (!inBounds(col, row)) return;
  const hit = squares[col + row * _N];
  if (hit !== null) {
    if (hit.side !== side) out.push([frm, [col, row], true]);
  } else {
    out.push([frm, [col, row], false]);
  }
}

// _emitRet: like _emit, returns true only if square was empty (slide continues)
function _emitRet(squares, frm, side, out, col, row) {
  if (!inBounds(col, row)) return false;
  const hit = squares[col + row * _N];
  if (hit !== null) {
    if (hit.side !== side) out.push([frm, [col, row], true]);
    return false;
  }
  out.push([frm, [col, row], false]);
  return true;
}

function _knightBlocked(squares, c, r, dc, dr) {
  const sc = dc > 0 ? 1 : -1;
  const sr = dr > 0 ? 1 : -1;
  const horiz = Math.abs(dc) > Math.abs(dr);
  const a  = occupied(squares, horiz ? c + sc : c,      horiz ? r      : r + sr);
  const b  = occupied(squares, c + sc,                   r + sr);
  const cc = occupied(squares, horiz ? c      : c + sc, horiz ? r + sr : r);
  const u  = occupied(squares, horiz ? c + 2*sc : c,    horiz ? r      : r + 2*sr);
  return (a && b) || (a && cc) || (b && u);
}

function _narrowLeapClear(squares, c, r, side, fwd, dist) {
  for (let j = 0; j <= dist; j++) {
    let clear = true;
    for (let k = 1; k <= j; k++) {
      if (occupied(squares, c, r + k * fwd)) { clear = false; break; }
    }
    if (!clear) continue;
    clear = true;
    for (let k = j; k <= dist - 1; k++) {
      if (occupied(squares, c + side, r + k * fwd)) { clear = false; break; }
    }
    if (clear) return true;
  }
  return false;
}

function _skjolding(squares, p, out) {
  const fwd = p.side === 'red' ? 1 : -1;
  const [c, r, frm, side] = [p.col, p.row, [p.col, p.row], p.side];
  if (!occupied(squares, c, r + fwd)) _emit(squares, frm, side, out, c, r + 2*fwd);
  for (const dc of [-1, 1]) {
    if (occupied(squares, c, r + fwd) && occupied(squares, c + dc, r)) continue;
    _emit(squares, frm, side, out, c + dc, r + fwd);
  }
  _emit(squares, frm, side, out, c, r - fwd);
}

function _berserker(squares, p, out) {
  const fwd = p.side === 'red' ? 1 : -1;
  const [c, r, frm, side] = [p.col, p.row, [p.col, p.row], p.side];
  for (const step of [1, 2, 3]) {
    if (!_emitRet(squares, frm, side, out, c, r + step * fwd)) break;
  }
  for (const dc of [-1, 1]) {
    for (const step of [1, 2, 3]) {
      if (!_narrowLeapClear(squares, c, r, dc, fwd, step)) continue;
      _emitRet(squares, frm, side, out, c + dc, r + step * fwd);
    }
  }
  for (const dc of [-1, 1]) {
    _emitRet(squares, frm, side, out, c + dc, r);
  }
}

function _spearman(squares, p, out) {
  const fwd = p.side === 'red' ? 1 : -1;
  const [c, r, frm, side] = [p.col, p.row, [p.col, p.row], p.side];
  const centerClear = _emitRet(squares, frm, side, out, c, r + fwd);
  let leftClear, rightClear;
  if (occupied(squares, c, r + fwd) && occupied(squares, c - 1, r)) {
    leftClear = false;
  } else {
    leftClear = _emitRet(squares, frm, side, out, c - 1, r + fwd);
  }
  if (occupied(squares, c, r + fwd) && occupied(squares, c + 1, r)) {
    rightClear = false;
  } else {
    rightClear = _emitRet(squares, frm, side, out, c + 1, r + fwd);
  }
  if (centerClear) _emitRet(squares, frm, side, out, c, r + 2*fwd);
  if (leftClear && !(occupied(squares, c-1, r+2*fwd) && occupied(squares, c-2, r+fwd)))
    _emitRet(squares, frm, side, out, c - 2, r + 2*fwd);
  if (rightClear && !(occupied(squares, c+1, r+2*fwd) && occupied(squares, c+2, r+fwd)))
    _emitRet(squares, frm, side, out, c + 2, r + 2*fwd);
  _emitRet(squares, frm, side, out, c, r - fwd);
}

function _wolf(squares, p, out) {
  const [c, r, frm, side] = [p.col, p.row, [p.col, p.row], p.side];
  for (const [dc, dr] of [[0,1],[0,-1],[1,0],[-1,0]]) {
    let col = c + dc, row = r + dr;
    for (let i = 0; i < 3; i++) {
      if (!inBounds(col, row)) break;
      const hit = squares[col + row * _N];
      if (hit !== null) {
        if (hit.side !== side) out.push([frm, [col, row], true]);
        break;
      }
      out.push([frm, [col, row], false]);
      col += dc; row += dr;
    }
  }
}

function _elf(squares, p, out) {
  const [c, r, frm, side] = [p.col, p.row, [p.col, p.row], p.side];
  for (const [dc, dr] of [[0,1],[0,-1],[1,0],[-1,0]]) {
    _emitRet(squares, frm, side, out, c + dc, r + dr);
  }
  for (const [dc, dr] of [[1,1],[1,-1],[-1,1],[-1,-1]]) {
    let col = c + dc, row = r + dr;
    for (let i = 0; i < 4; i++) {
      if (occupied(squares, col, row - dr) && occupied(squares, col - dc, row)) break;
      if (!_emitRet(squares, frm, side, out, col, row)) break;
      col += dc; row += dr;
    }
  }
}

function _king(squares, p, out) {
  const [c, r, frm, side] = [p.col, p.row, [p.col, p.row], p.side];
  for (const [dc, dr] of [[0,1],[0,-1],[1,0],[-1,0]]) {
    _emit(squares, frm, side, out, c + dc, r + dr);
  }
  for (const [dc, dr] of [[1,1],[1,-1],[-1,1],[-1,-1]]) {
    if (occupied(squares, c, r + dr) && occupied(squares, c + dc, r)) continue;
    _emit(squares, frm, side, out, c + dc, r + dr);
  }
}

function _dwarf(squares, p, out) {
  const [c, r, frm, side] = [p.col, p.row, [p.col, p.row], p.side];
  for (const [dc, dr] of [[0,1],[0,-1],[1,0],[-1,0]]) {
    for (const step of [1, 2]) {
      if (!_emitRet(squares, frm, side, out, c + dc*step, r + dr*step)) break;
    }
  }
  for (const [dc, dr] of [[1,1],[1,-1],[-1,1],[-1,-1]]) {
    if (occupied(squares, c, r + dr) && occupied(squares, c + dc, r)) continue;
    if (occupied(squares, c + dc, r + dr)) continue;
    if (occupied(squares, c + dc, r + 2*dr) && occupied(squares, c + 2*dc, r + dr)) continue;
    _emitRet(squares, frm, side, out, c + dc*2, r + dr*2);
  }
  for (const [dc, dr] of KNIGHT_OFFSETS) {
    if (_knightBlocked(squares, c, r, dc, dr)) continue;
    _emitRet(squares, frm, side, out, c + dc, r + dr);
  }
}

function _hunter(squares, p, out) {
  const [c, r, frm, side] = [p.col, p.row, [p.col, p.row], p.side];
  for (const [dc, dr] of [[1,1],[1,-1],[-1,1],[-1,-1]]) {
    if (occupied(squares, c, r + dr) && occupied(squares, c + dc, r)) continue;
    _emit(squares, frm, side, out, c + dc, r + dr);
  }
  for (const [dc, dr] of KNIGHT_OFFSETS) {
    if (_knightBlocked(squares, c, r, dc, dr)) continue;
    _emit(squares, frm, side, out, c + dc, r + dr);
  }
}

function _bowman(squares, p, out) {
  const fwd = p.side === 'red' ? 1 : -1;
  const [c, r, frm, side] = [p.col, p.row, [p.col, p.row], p.side];
  for (const step of [1, 2, 3, 4]) {
    if (!_emitRet(squares, frm, side, out, c, r + step * fwd)) break;
  }
  for (const dc of [-1, 1]) {
    _emitRet(squares, frm, side, out, c + dc, r);
  }
}

const GENERATORS = {
  skjolding: _skjolding, berserker: _berserker, spearman: _spearman,
  wolf: _wolf, elf: _elf, king: _king, dwarf: _dwarf, hunter: _hunter, bowman: _bowman,
};

// --- Public Board API ---

function legalMoves(board) {
  const out = [];
  for (const sq of board.squares) {
    if (sq === null || sq.side !== board.sideToMove) continue;
    GENERATORS[sq.type](board.squares, sq, out);
  }
  return out;
}

function kingPosition(squares, side) {
  for (const sq of squares) {
    if (sq !== null && sq.type === 'king' && sq.side === side) return [sq.col, sq.row];
  }
  return null;
}

function hasFortControl(squares, side) {
  const opp = otherSide(side);
  let inOpp = false, oppDefends = false;
  for (const sq of squares) {
    if (sq === null) continue;
    if (sq.side === side && isFort(sq.col, sq.row, opp)) inOpp = true;
    if (sq.side === opp  && isFort(sq.col, sq.row, opp)) oppDefends = true;
  }
  return inOpp && !oppDefends;
}

function applyMove(board, move) {
  const [frm, to] = move;
  const squares = board.squares.map(s => s ? { ...s } : null);
  const fromIdx = frm[0] + frm[1] * _N;
  const toIdx   = to[0]  + to[1]  * _N;
  const mover = squares[fromIdx];
  if (!mover) return { ...board, squares };
  const moverSide = mover.side;
  let winner = null, winReason = null;

  const captured = squares[toIdx];
  if (captured && captured.type === 'king') {
    winner = moverSide; winReason = 'kingCapture';
  }

  squares[toIdx] = { type: mover.type, side: mover.side, col: to[0], row: to[1] };
  squares[fromIdx] = null;
  const nextSide = otherSide(moverSide);

  if (winner) return { squares, sideToMove: nextSide, winner, winReason };

  const claimant = nextSide;
  const kp = kingPosition(squares, claimant);
  if (kp && kp[0] === CASTLE[0] && kp[1] === CASTLE[1]) {
    return { squares, sideToMove: nextSide, winner: claimant, winReason: 'castle' };
  }
  if (hasFortControl(squares, claimant)) {
    return { squares, sideToMove: nextSide, winner: claimant, winReason: 'fort' };
  }
  return { squares, sideToMove: nextSide, winner: null, winReason: null };
}

function staticOutcome(board) {
  const stm = board.sideToMove;
  const kp = kingPosition(board.squares, stm);
  if (!kp) return [otherSide(stm), 'kingCapture'];
  if (kp[0] === CASTLE[0] && kp[1] === CASTLE[1]) return [stm, 'castle'];
  if (hasFortControl(board.squares, stm)) return [stm, 'fort'];
  return [null, null];
}

D.repetitionKey  = repetitionKey;
D.legalMoves     = legalMoves;
D.applyMove      = applyMove;
D.staticOutcome  = staticOutcome;
D.kingPosition   = kingPosition;
D.hasFortControl = hasFortControl;
D.otherSide      = otherSide;
D.inBounds       = inBounds;
D.isFort         = isFort;
D.TYPE_CODE      = TYPE_CODE;
D.CASTLE         = CASTLE;
D.RED_FORT       = RED_FORT;
D.BLACK_FORT     = BLACK_FORT;

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    repetitionKey, legalMoves, applyMove, staticOutcome,
    kingPosition, hasFortControl, otherSide, inBounds, isFort,
    TYPE_CODE, CASTLE, RED_FORT, BLACK_FORT,
  };
}
})();
