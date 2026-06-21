// renderer.js — SVG board, piece rendering, click/drag, highlights, navigation
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

const NS      = 'http://www.w3.org/2000/svg';
const SQ      = 70;
const BOARD_PX = SQ * 9; // 630

// --- SVG piece loading (Node.js, available in Electron renderer) ---
const _fs   = typeof require !== 'undefined' ? require('fs')   : null;
const _path = typeof require !== 'undefined' ? require('path') : null;
const _base = typeof __dirname !== 'undefined' ? __dirname : '.';
const _svgCache = {};

function _pieceSVGUri(type, side) {
  const key = `${type}-${side}`;
  if (_svgCache[key]) return _svgCache[key];
  if (!_fs) return '';
  let raw;
  try { raw = _fs.readFileSync(_path.join(_base, 'assets', 'pieces', `${type}.svg`), 'utf8'); }
  catch (_) { return ''; }
  const color = side === 'red' ? '#B83030' : '#171410';
  raw = raw.replace(/fill="black"/g, `fill="${color}"`).replace(/fill='black'/g, `fill='${color}'`);
  _svgCache[key] = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(raw);
  return _svgCache[key];
}

// --- Coord helpers ---
function colRowToXY(col, row) {
  return [col * SQ + SQ / 2, (8 - row) * SQ + SQ / 2];
}
function xyToColRow(x, y) {
  return [Math.floor(x / SQ), 8 - Math.floor(y / SQ)];
}

// --- Square category ---
function squareCat(col, row) {
  if (col === 4 && row === 4) return 'castle';
  if (Math.abs(col - 4) <= 1 && Math.abs(row - 4) <= 1) return 'zone';
  if (col === 4 && (row === 2 || row === 6)) return 'zone';
  if (row === 4 && (col === 2 || col === 6)) return 'zone';
  if (D.RED_FORT   && D.RED_FORT.has(`${col},${row}`))   return 'fort';
  if (D.BLACK_FORT && D.BLACK_FORT.has(`${col},${row}`)) return 'fort';
  return 'normal';
}

const COL = {
  normal : '#EDE4CC',
  fort   : '#C0A878',
  zone   : '#E4D8B0',
  castle : '#C8A030',
};

// --- SVG element helpers ---
let svg, pieceLayer, highlightLayer;
function el(tag) { return document.createElementNS(NS, tag); }
function sa(e, attrs) { for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v); return e; }

// --- Board initialisation ---
function initBoard() {
  const container = document.getElementById('board-container');
  svg = sa(el('svg'), {
    width: BOARD_PX, height: BOARD_PX,
    viewBox: `0 0 ${BOARD_PX} ${BOARD_PX}`,
    id: 'board-svg',
  });
  container.appendChild(svg);

  const defs = el('defs');
  svg.appendChild(defs);

  // Fort texture: diagonal crosshatch lines
  const fortPat = sa(el('pattern'), {
    id: 'fort-tex', x: 0, y: 0, width: 10, height: 10, patternUnits: 'userSpaceOnUse',
  });
  fortPat.append(
    sa(el('line'), { x1:0,y1:10,  x2:10,y2:0,   stroke:'rgba(0,0,0,0.11)', 'stroke-width':0.8 }),
    sa(el('line'), { x1:-2,y1:2,  x2:2,y2:-2,   stroke:'rgba(0,0,0,0.11)', 'stroke-width':0.8 }),
    sa(el('line'), { x1:8,y1:12,  x2:12,y2:8,   stroke:'rgba(0,0,0,0.11)', 'stroke-width':0.8 }),
  );
  defs.appendChild(fortPat);

  // Castle zone texture: evenly-spaced warm dots
  const zonePat = sa(el('pattern'), {
    id: 'zone-tex', x: 0, y: 0, width: 12, height: 12, patternUnits: 'userSpaceOnUse',
  });
  for (const [cx, cy] of [[6,6],[0,0],[12,0],[0,12],[12,12]]) {
    zonePat.appendChild(sa(el('circle'), { cx, cy, r:1.4, fill:'rgba(130,95,0,0.22)' }));
  }
  defs.appendChild(zonePat);

  // Castle texture: brick/masonry rows
  const castlePat = sa(el('pattern'), {
    id: 'castle-tex', x: 0, y: 0, width: 16, height: 10, patternUnits: 'userSpaceOnUse',
  });
  for (const [x, y, w, h] of [[0,0,8,5],[8,0,8,5],[4,5,8,5],[-4,5,8,5],[12,5,8,5]]) {
    castlePat.appendChild(sa(el('rect'), {
      x, y, width:w, height:h, fill:'none',
      stroke:'rgba(80,50,0,0.22)', 'stroke-width':0.6,
    }));
  }
  defs.appendChild(castlePat);

  const bg = el('g');
  svg.appendChild(bg);

  bg.appendChild(sa(el('rect'), { width: BOARD_PX, height: BOARD_PX, fill: '#2a2010' }));

  const G = 1.5, RX = 12;
  for (let row = 0; row < 9; row++) {
    for (let col = 0; col < 9; col++) {
      const cat = squareCat(col, row);
      const x = col * SQ + G, y = (8 - row) * SQ + G;
      const w = SQ - G * 2, h = SQ - G * 2;
      bg.appendChild(sa(el('rect'), { x, y, width:w, height:h, fill:COL[cat], rx:RX }));
      if (cat !== 'normal') {
        const texId = cat === 'fort' ? 'fort-tex' : cat === 'zone' ? 'zone-tex' : 'castle-tex';
        const tex = sa(el('rect'), { x, y, width:w, height:h, fill:`url(#${texId})`, rx:RX });
        tex.style.pointerEvents = 'none';
        bg.appendChild(tex);
      }
    }
  }

  const [ccx, ccy] = colRowToXY(4, 4);
  bg.appendChild(sa(el('circle'), {
    cx:ccx, cy:ccy, r:8,
    fill:'none', stroke:'rgba(80,50,0,0.45)', 'stroke-width':1.8,
  }));

  highlightLayer = el('g');
  bg.appendChild(highlightLayer);

  pieceLayer = el('g');
  pieceLayer.style.pointerEvents = 'none';
  bg.appendChild(pieceLayer);

  const clickLayer = el('g');
  for (let row = 0; row < 9; row++) {
    for (let col = 0; col < 9; col++) {
      const r = sa(el('rect'), {
        x:col*SQ, y:(8-row)*SQ, width:SQ, height:SQ, fill:'transparent',
      });
      r.dataset.col = col; r.dataset.row = row;
      r.addEventListener('click', onSquareClick);
      r.addEventListener('mousedown', onDragStart);
      clickLayer.appendChild(r);
    }
  }
  bg.appendChild(clickLayer);
}

// --- Piece rendering ---
function renderPieces() {
  while (pieceLayer.firstChild) pieceLayer.removeChild(pieceLayer.firstChild);
  if (!D.board) return;
  const size = SQ * 0.78;
  for (const sq of viewBoard().squares) {
    if (!sq) continue;
    const [x, y] = colRowToXY(sq.col, sq.row);
    pieceLayer.appendChild(sa(el('image'), {
      href: _pieceSVGUri(sq.type, sq.side),
      x: x - size/2, y: y - size/2, width: size, height: size,
    }));
  }
}

// --- Highlights ---
function clearHighlights() {
  while (highlightLayer.firstChild) highlightLayer.removeChild(highlightLayer.firstChild);
}

D.toggleAttackMap = function() {
  D.showAttackMap = !D.showAttackMap;
  const btn = document.getElementById('attack-map-btn');
  if (btn) btn.classList.toggle('active', D.showAttackMap);
  showHighlights();
};

function _buildAttackMap(board) {
  const red = new Array(81).fill(0);
  const blk = new Array(81).fill(0);
  const redBoard = { ...board, sideToMove: 'red' };
  const blkBoard = { ...board, sideToMove: 'black' };
  for (const [, to] of D.legalMoves(redBoard)) red[to[0] + to[1] * 9]++;
  for (const [, to] of D.legalMoves(blkBoard)) blk[to[0] + to[1] * 9]++;
  return { red, blk };
}

function showHighlights() {
  clearHighlights();
  // Last-move tint — for browsing use boardHistory diff, for live use D.lastMove
  const tintMove = D.viewIndex !== null
    ? (D.viewIndex > 0 ? _historyMove(D.viewIndex) : null)
    : D.lastMove;
  if (tintMove) {
    for (const [lc, lr] of tintMove) {
      highlightLayer.appendChild(sa(el('rect'), {
        x: lc*SQ + 1.5, y: (8-lr)*SQ + 1.5, width: SQ - 3, height: SQ - 3,
        fill: 'rgba(220,185,20,0.50)', rx: 11,
      }));
    }
  }
  if (D.showAttackMap) {
    const brd = viewBoard();
    if (brd) {
      const { red, blk } = _buildAttackMap(brd);
      const maxCount = 6;
      for (let i = 0; i < 81; i++) {
        const r = red[i], b = blk[i];
        if (!r && !b) continue;
        const col = i % 9, row = Math.floor(i / 9);
        const x = col * SQ, y = (8 - row) * SQ;
        if (r > b) {
          const alpha = Math.min(r / maxCount, 1) * 0.35;
          highlightLayer.appendChild(sa(el('rect'), { x, y, width:SQ, height:SQ, fill:`rgba(180,40,40,${alpha.toFixed(2)})` }));
        } else if (b > r) {
          const alpha = Math.min(b / maxCount, 1) * 0.35;
          highlightLayer.appendChild(sa(el('rect'), { x, y, width:SQ, height:SQ, fill:`rgba(40,80,180,${alpha.toFixed(2)})` }));
        } else {
          highlightLayer.appendChild(sa(el('rect'), { x, y, width:SQ, height:SQ, fill:'rgba(120,80,160,0.20)' }));
        }
      }
    }
  }

  if (!D.selected) return;
  const [sc, sr] = D.selected;
  const sx = sc * SQ, sy = (8 - sr) * SQ;
  highlightLayer.appendChild(sa(el('rect'), {
    x:sx+2, y:sy+2, width:SQ-4, height:SQ-4,
    fill:'rgba(255,220,0,0.18)', stroke:'rgba(255,200,0,0.85)',
    'stroke-width':2.5, rx:3,
  }));
  for (const move of D.validMoves) {
    const [, to, isCapture] = move;
    const [cx, cy] = colRowToXY(to[0], to[1]);
    if (isCapture) {
      highlightLayer.appendChild(sa(el('circle'), {
        cx, cy, r:SQ*0.38,
        fill:'none', stroke:'rgba(220,60,50,0.8)', 'stroke-width':2.5,
      }));
    } else {
      highlightLayer.appendChild(sa(el('circle'), {
        cx, cy, r:10, fill:'rgba(255,210,0,0.55)',
      }));
    }
  }
}

// --- Click handling ---
function onSquareClick(e) {
  e.stopPropagation();
  handleSquareClick(parseInt(e.currentTarget.dataset.col), parseInt(e.currentTarget.dataset.row));
}

function viewBoard() {
  return D.viewIndex !== null ? D.boardHistory[D.viewIndex] : D.board;
}

function _historyMove(idx) {
  const prev = D.boardHistory[idx - 1];
  const curr = D.boardHistory[idx];
  let from = null, to = null;
  for (let i = 0; i < 81; i++) {
    if (prev.squares[i] && !curr.squares[i]) from = [i % 9, Math.floor(i / 9)];
    if (!prev.squares[i] && curr.squares[i]) to   = [i % 9, Math.floor(i / 9)];
    if (prev.squares[i] && curr.squares[i] && prev.squares[i].side !== curr.squares[i].side) to = [i % 9, Math.floor(i / 9)];
  }
  return from && to ? [from, to] : null;
}

// --- Navigation ---
D.navTo = function(idx) {
  if (!D.boardHistory.length) return;
  if (idx === null || idx >= D.boardHistory.length - 1) {
    D.viewIndex = null;
  } else {
    D.viewIndex = Math.max(0, idx);
  }
  D.selected = null; D.validMoves = [];
  renderPieces(); showHighlights(); D.updateMoveList();
  if (D._postGameReview || D.analysisMode) D.syncEvalBar(D.viewIndex);
};
D.navBack    = function() { D.navTo(D.viewIndex !== null ? D.viewIndex - 1 : D.boardHistory.length - 2); };
D.navForward = function() { D.navTo(D.viewIndex !== null ? D.viewIndex + 1 : null); };

D.toggleAnalysis = function() {
  D.analysisMode = !D.analysisMode;
  const btn = document.getElementById('analyse-btn');
  if (btn) btn.classList.toggle('active', D.analysisMode);
  D.selected = null; D.validMoves = [];
  const evalWrap = document.getElementById('eval-bar-wrap');
  if (evalWrap) evalWrap.style.display = (D.analysisMode || D._postGameReview) ? '' : 'none';
  showHighlights(); D.updateHUD();
};

function handleSquareClick(col, row) {
  if (D.viewIndex !== null) return;
  if (D.checkPendingWin()) return;

  // Analysis mode: free movement of any piece, no AI trigger, no rules enforcement
  if (D.analysisMode) {
    const sq = D.board.squares[col + row * D.N];
    if (D.selected) {
      const move = D.validMoves.find(m => m[1][0] === col && m[1][1] === row);
      if (move) {
        D.board = D.applyMove(D.board, move);
        D.lastMove = [move[0], move[1]];
        D.selected = null; D.validMoves = [];
        renderPieces(); showHighlights();
        return;
      }
      if (sq) { selectPiece(col, row); return; }
      D.selected = null; D.validMoves = []; showHighlights();
      return;
    }
    if (sq) selectPiece(col, row);
    return;
  }

  if (D.gamePhase !== 'playing') return;
  const setup = D.board.sideToMove === 'red' ? D.redSetup : D.blackSetup;
  if (setup.kind !== 'human') return;

  const sq = D.board.squares[col + row * D.N];

  if (D.selected) {
    const move = D.validMoves.find(m => m[1][0] === col && m[1][1] === row);
    if (move) { D.executeMove(move); return; }
    if (sq && sq.side === D.board.sideToMove) { selectPiece(col, row); return; }
    D.selected = null; D.validMoves = []; showHighlights();
    return;
  }
  if (sq && sq.side === D.board.sideToMove) selectPiece(col, row);
}

// --- Drag to move ---
let _drag = null;

function onDragStart(e) {
  if (D.viewIndex !== null) return;
  if (!D.analysisMode) {
    if (D.gamePhase !== 'playing') return;
    const setup = D.board.sideToMove === 'red' ? D.redSetup : D.blackSetup;
    if (setup.kind !== 'human') return;
  }
  const col = parseInt(e.currentTarget.dataset.col);
  const row = parseInt(e.currentTarget.dataset.row);
  const sq = D.board.squares[col + row * D.N];
  if (!sq) return;
  if (!D.analysisMode && sq.side !== D.board.sideToMove) return;

  e.preventDefault();
  selectPiece(col, row);

  const size = SQ * 0.88;
  const ghost = document.createElement('img');
  ghost.src = _pieceSVGUri(sq.type, sq.side);
  Object.assign(ghost.style, {
    position:'fixed', width:`${size}px`, height:`${size}px`,
    pointerEvents:'none', opacity:'0.85', zIndex:'9999',
    transform:'translate(-50%,-50%)', userSelect:'none',
  });
  document.body.appendChild(ghost);

  const svgRect = e.currentTarget.closest('svg').getBoundingClientRect();
  _drag = { col, row, ghost, svgRect };
  _moveDragGhost(e);
  document.addEventListener('mousemove', onDragMove);
  document.addEventListener('mouseup', onDragEnd);
}

function _moveDragGhost(e) {
  if (!_drag) return;
  _drag.ghost.style.left = `${e.clientX}px`;
  _drag.ghost.style.top  = `${e.clientY}px`;
}

function onDragMove(e) { _moveDragGhost(e); }

function onDragEnd(e) {
  document.removeEventListener('mousemove', onDragMove);
  document.removeEventListener('mouseup', onDragEnd);
  if (!_drag) return;
  _drag.ghost.remove();

  const { svgRect } = _drag;
  const lx = e.clientX - svgRect.left, ly = e.clientY - svgRect.top;
  const tc = Math.floor(lx / SQ), tr = 8 - Math.floor(ly / SQ);
  _drag = null;

  if (tc < 0 || tc > 8 || tr < 0 || tr > 8) { return; }
  const move = D.validMoves.find(m => m[1][0] === tc && m[1][1] === tr);
  if (move) {
    D.executeMove(move);
  }
}

function selectPiece(col, row) {
  D.selected = [col, row];
  if (D.analysisMode) {
    const sq = D.board.squares[col + row * D.N];
    if (sq) {
      const tempBoard = { ...D.board, sideToMove: sq.side };
      const all = D.legalMoves(tempBoard);
      D.validMoves = all.filter(m => m[0][0] === col && m[0][1] === row);
    } else {
      D.validMoves = [];
    }
  } else {
    const all = D.legalMoves(D.board);
    D.validMoves = all.filter(m => m[0][0] === col && m[0][1] === row);
  }
  showHighlights();
}

// --- Piece legend ---
const _LEGEND_PIECES = [
  { type:'king',      abbr:'K',  name:'King'      },
  { type:'pawn',      abbr:'V',  name:'Skjolding' },
  { type:'spearman',  abbr:'Sp', name:'Spearman'  },
  { type:'bowman',    abbr:'Bw', name:'Bowman'    },
  { type:'berserker', abbr:'Bk', name:'Berserker' },
  { type:'sword',     abbr:'Sw', name:'Sword'     },
  { type:'wolf',      abbr:'Wo', name:'Wolf'      },
  { type:'axe',       abbr:'Ax', name:'Axe'       },
  { type:'hunter',    abbr:'Hu', name:'Hunter'    },
];

D.buildPieceLegend = function() {
  const el = document.getElementById('piece-legend');
  if (!el || el.dataset.built) return;
  el.dataset.built = '1';
  el.innerHTML = _LEGEND_PIECES.map(p => `
    <div class="legend-item">
      <img src="${_pieceSVGUri(p.type, 'red')}" class="legend-icon" alt="${p.name}">
      <span class="legend-abbr">${p.abbr}</span>
      <span class="legend-name">${p.name}</span>
    </div>`).join('');
};

window.addEventListener('DOMContentLoaded', () => {
  initBoard();
  D.newGame();
});

document.addEventListener('keydown', e => {
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT' || e.target.tagName === 'TEXTAREA') return;
  if (e.key === 'ArrowLeft')  { e.preventDefault(); D.navBack(); }
  if (e.key === 'ArrowRight') { e.preventDefault(); D.navForward(); }
  if (e.key === 'Home')       { e.preventDefault(); D.navTo(0); }
  if (e.key === 'End')        { e.preventDefault(); D.navTo(null); }
});

D.colRowToXY      = colRowToXY;
D.renderPieces    = renderPieces;
D.clearHighlights = clearHighlights;
D.showHighlights  = showHighlights;
D.SQ = SQ;

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { colRowToXY, SQ };
}
})();
