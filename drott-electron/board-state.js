// board-state.js — 9×9 board state + snapshot/restore for AI search
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

const N = 9;

// SVG asset path for a piece type (renderer handles colouring by side)
function pieceAsset(type) {
  return `assets/pieces/${type}.svg`;
}

// Start position: list of {type, side, col, row}
const START_PIECES = [
  // Red
  { type: 'skjolding', side: 'red', col: 1, row: 0 },
  { type: 'wolf',      side: 'red', col: 2, row: 0 },
  { type: 'elf',       side: 'red', col: 3, row: 0 },
  { type: 'king',      side: 'red', col: 4, row: 0 },
  { type: 'dwarf',     side: 'red', col: 5, row: 0 },
  { type: 'hunter',    side: 'red', col: 6, row: 0 },
  { type: 'skjolding', side: 'red', col: 7, row: 0 },
  { type: 'skjolding', side: 'red', col: 2, row: 1 },
  { type: 'berserker', side: 'red', col: 3, row: 1 },
  { type: 'spearman',  side: 'red', col: 4, row: 1 },
  { type: 'bowman',    side: 'red', col: 5, row: 1 },
  { type: 'skjolding', side: 'red', col: 6, row: 1 },
  { type: 'skjolding', side: 'red', col: 3, row: 2 },
  { type: 'skjolding', side: 'red', col: 4, row: 2 },
  { type: 'skjolding', side: 'red', col: 5, row: 2 },
  // Black (point-symmetric: col → 8-col, row → 8-row)
  { type: 'skjolding', side: 'black', col: 7, row: 8 },
  { type: 'wolf',      side: 'black', col: 6, row: 8 },
  { type: 'elf',       side: 'black', col: 5, row: 8 },
  { type: 'king',      side: 'black', col: 4, row: 8 },
  { type: 'dwarf',     side: 'black', col: 3, row: 8 },
  { type: 'hunter',    side: 'black', col: 2, row: 8 },
  { type: 'skjolding', side: 'black', col: 1, row: 8 },
  { type: 'skjolding', side: 'black', col: 6, row: 7 },
  { type: 'berserker', side: 'black', col: 5, row: 7 },
  { type: 'spearman',  side: 'black', col: 4, row: 7 },
  { type: 'bowman',    side: 'black', col: 3, row: 7 },
  { type: 'skjolding', side: 'black', col: 2, row: 7 },
  { type: 'skjolding', side: 'black', col: 5, row: 6 },
  { type: 'skjolding', side: 'black', col: 4, row: 6 },
  { type: 'skjolding', side: 'black', col: 3, row: 6 },
];

function makeStartBoard() {
  const squares = new Array(N * N).fill(null);
  for (const p of START_PIECES) {
    squares[p.col + p.row * N] = { type: p.type, side: p.side, col: p.col, row: p.row };
  }
  return { squares, sideToMove: 'red', winner: null, winReason: null };
}

function cloneBoard(b) {
  return {
    squares: b.squares.map(s => s ? { ...s } : null),
    sideToMove: b.sideToMove,
    winner: b.winner,
    winReason: b.winReason,
  };
}

D.N = N;
D.pieceAsset = pieceAsset;
D.makeStartBoard = makeStartBoard;
D.cloneBoard = cloneBoard;

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { N, pieceAsset, makeStartBoard, cloneBoard, START_PIECES };
}
})();
