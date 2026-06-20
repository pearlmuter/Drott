// renderer.js — SVG board, piece rendering, click handling, game state machine
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

const NS      = 'http://www.w3.org/2000/svg';
const SQ      = 70;
const BOARD_PX = SQ * 9; // 630

D.board         = null;
D.selected      = null;
D.validMoves    = [];
D.repCounts     = {};
D.gamePhase     = 'setup';
D.moveHistory   = [];   // [{notation, side}]
D.capturedRed   = [];   // piece types Red captured (i.e. Black pieces taken)
D.capturedBlack = [];   // piece types Black captured (i.e. Red pieces taken)
D.lastMove      = null; // [[fromCol,fromRow],[toCol,toRow]] of the most recent move
D.boardHistory  = [];   // board snapshot after each half-move (index 0 = start pos)
D.viewIndex     = null; // null = live; number = browsing historical position
D.showAttackMap = false;

D.redSetup   = { kind: 'human', thinkTime: 5, model: 'astrid_v0', iterations: 100 };
D.blackSetup = { kind: 'human', thinkTime: 5, model: 'astrid_v0', iterations: 100 };

const COLS = 'ABCDEFGHI';
function moveNotation(move) {
  const [[fc, fr], [tc, tr], cap] = move;
  return `${COLS[fc]}${fr + 1}${cap ? 'x' : '-'}${COLS[tc]}${tr + 1}`;
}

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

// Colors: normal cream → fort (darker shade) → zone (slightly golden) → castle (amber)
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

  // All board drawing goes inside this group (container div clips rounded corners)
  const bg = el('g');
  svg.appendChild(bg);

  // Board gap fill (shows between rounded squares)
  bg.appendChild(sa(el('rect'), { width: BOARD_PX, height: BOARD_PX, fill: '#2a2010' }));

  // All 81 squares as individual rounded rects — 3px gap between squares, rx = 12
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

  // Castle ring marker
  const [ccx, ccy] = colRowToXY(4, 4);
  bg.appendChild(sa(el('circle'), {
    cx:ccx, cy:ccy, r:8,
    fill:'none', stroke:'rgba(80,50,0,0.45)', 'stroke-width':1.8,
  }));

  // Coordinate labels rendered outside SVG as HTML (see initCoordLabels)

  // Highlight layer (below pieces)
  highlightLayer = el('g');
  bg.appendChild(highlightLayer);

  // Piece layer
  pieceLayer = el('g');
  pieceLayer.style.pointerEvents = 'none';
  bg.appendChild(pieceLayer);

  // Click + drag layer
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
  // Attack map overlay
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
  // Selection ring
  const sx = sc * SQ, sy = (8 - sr) * SQ;
  highlightLayer.appendChild(sa(el('rect'), {
    x:sx+2, y:sy+2, width:SQ-4, height:SQ-4,
    fill:'rgba(255,220,0,0.18)', stroke:'rgba(255,200,0,0.85)',
    'stroke-width':2.5, rx:3,
  }));
  // Move dots / capture rings
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
  // Recover from/to from the notation stored at moveHistory[idx-1]
  // We store full squares in boardHistory so we can diff
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
function _evalAtIndex(idx) {
  if (!D.evalHistory) return undefined;
  // evalHistory is sparse — walk back to find the nearest recorded value
  for (let i = idx; i >= 0; i--) {
    if (D.evalHistory[i] !== undefined) return D.evalHistory[i];
  }
  return undefined;
}

function _syncEvalBar(viewIdx) {
  const pos = viewIdx !== null ? viewIdx : (D.boardHistory ? D.boardHistory.length - 1 : 0);
  const bar = document.getElementById('eval-bar-black');
  const evalLine = document.getElementById('eval-line');
  const val = _evalAtIndex(pos);
  if (val === undefined) {
    if (bar) bar.style.height = '50%';
    if (evalLine) evalLine.textContent = '';
    return;
  }
  const MAX_CP = 800;
  const pct = Math.max(0, Math.min(1, (val + MAX_CP) / (2 * MAX_CP)));
  if (bar) bar.style.height = `${((1 - pct) * 100).toFixed(1)}%`;
  if (evalLine) {
    const MATE = 100000;
    if (Math.abs(val) >= MATE - 200) {
      const m = Math.ceil((MATE - Math.abs(val)) / 2);
      evalLine.textContent = val > 0 ? `#${m}` : `-#${m}`;
    } else {
      const cp = (val / 100).toFixed(2);
      evalLine.textContent = val >= 0 ? `+${cp}` : `${cp}`;
    }
  }
}

D.navTo = function(idx) {
  if (!D.boardHistory.length) return;
  if (idx === null || idx >= D.boardHistory.length - 1) {
    D.viewIndex = null;
  } else {
    D.viewIndex = Math.max(0, idx);
  }
  D.selected = null; D.validMoves = [];
  renderPieces(); showHighlights(); updateMoveList();
  if (D._postGameReview || D.analysisMode) _syncEvalBar(D.viewIndex);
};
D.navBack    = function() { D.navTo(D.viewIndex !== null ? D.viewIndex - 1 : D.boardHistory.length - 2); };
D.navForward = function() { D.navTo(D.viewIndex !== null ? D.viewIndex + 1 : null); };

D.analysisMode = false;

D.toggleAnalysis = function() {
  D.analysisMode = !D.analysisMode;
  const btn = document.getElementById('analyse-btn');
  if (btn) btn.classList.toggle('active', D.analysisMode);
  D.selected = null; D.validMoves = [];
  const evalWrap = document.getElementById('eval-bar-wrap');
  if (evalWrap) evalWrap.style.display = (D.analysisMode || D._postGameReview) ? '' : 'none';
  showHighlights(); updateHUD();
};

function handleSquareClick(col, row) {
  if (D.viewIndex !== null) return;
  if (checkPendingWin()) return;

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
    if (move) { executeMove(move); return; }
    if (sq && sq.side === D.board.sideToMove) { selectPiece(col, row); return; }
    D.selected = null; D.validMoves = []; showHighlights();
    return;
  }
  if (sq && sq.side === D.board.sideToMove) selectPiece(col, row);
}

// --- Drag to move ---
let _drag = null; // { col, row, ghost, offsetX, offsetY }

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

  // Create floating ghost image
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

  // Determine which square the cursor is over
  const { svgRect } = _drag;
  const lx = e.clientX - svgRect.left, ly = e.clientY - svgRect.top;
  const tc = Math.floor(lx / SQ), tr = 8 - Math.floor(ly / SQ);
  _drag = null;

  if (tc < 0 || tc > 8 || tr < 0 || tr > 8) { return; }
  const move = D.validMoves.find(m => m[1][0] === tc && m[1][1] === tr);
  if (move) {
    executeMove(move);
  }
  // Leave selection visible if no valid destination (same as click behaviour)
}

function selectPiece(col, row) {
  D.selected = [col, row];
  if (D.analysisMode) {
    // In analysis mode, generate moves for whichever side owns the piece
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

function checkPendingWin() {
  if (!D._pendingWin) return false;
  const pw = D._pendingWin; D._pendingWin = null;
  endGame(pw.winner, pw.reason);
  return true;
}

function executeMove(move) {
  if (checkPendingWin()) return;
  const side = D.board.sideToMove;
  if (move[2]) {  // capture: record captured piece before applying
    const [, to] = move;
    const cap = D.board.squares[to[0] + to[1] * D.N];
    if (cap) (side === 'red' ? D.capturedRed : D.capturedBlack).push(cap.type);
  }
  D.moveHistory.push({ notation: moveNotation(move), side });
  D.lastMove = [move[0], move[1]];
  D.board = D.applyMove(D.board, move);
  D.boardHistory.push(D.board);
  D.viewIndex = null;
  const key = D.repetitionKey(D.board).toString();
  D.repCounts[key] = (D.repCounts[key] || 0) + 1;
  D.selected = null; D.validMoves = [];
  renderPieces(); showHighlights(); updateHUD(); updateMoveList(); updateCaptured();
  if (D.board.winner) {
    if (D.board.winReason === 'kingCapture') {
      endGame(D.board.winner, D.board.winReason); return;
    }
    // castle/fort: defer — win fires at the START of the winner's next turn
    D._pendingWin = { winner: D.board.winner, reason: D.board.winReason };
    D.board = { ...D.board, winner: null, winReason: null };
  }
  if (D.repCounts[key] >= 3) { endGame(null, 'repetition'); return; }
  scheduleAI();
}

// --- Game flow ---
function _resetBoard() {
  if (D.terminateHRWorker) D.terminateHRWorker();
  D.isAILocked = false;
  D.board = D.makeStartBoard();
  D.repCounts = {};
  D.selected = null; D.validMoves = [];
  D.moveHistory = []; D.capturedRed = []; D.capturedBlack = []; D.lastMove = null;
  D.boardHistory = [D.board]; D.viewIndex = null; D.evalHistory = [];
  D._pendingWin = null; D._postGameReview = false; D.analysisMode = false;
  const ab = document.getElementById('analyse-btn'); if (ab) ab.classList.remove('active');
  document.getElementById('result-banner').style.display = 'none';
  const evalWrap = document.getElementById('eval-bar-wrap');
  if (evalWrap) evalWrap.style.display = 'none';
  const evalGraph = document.getElementById('eval-graph-section');
  if (evalGraph) evalGraph.style.display = 'none';
  if (D.showEval) D.showEval(null);
}

// "New Game" — reset to setup state, show start position, no AI running.
// Lets the user configure sides/strength before committing to play.
D.newGame = function() {
  _resetBoard();
  D.gamePhase = 'setup';
  clearHighlights(); renderPieces(); updateHUD(); updateMoveList(); updateCaptured();
};

// "Start" — begin playing from current configuration.
// Also used internally (loadGame, resign replay) to start a fresh game.
D.startGame = function() {
  _resetBoard();
  D.gamePhase = 'playing';
  clearHighlights(); renderPieces(); updateHUD(); updateMoveList(); updateCaptured();
  scheduleAI();
};

D.abortGame = function() {
  if (D.gamePhase !== 'playing') return;
  if (D.terminateHRWorker) D.terminateHRWorker();
  D.isAILocked = false;
  D._pendingWin = null;
  D.gamePhase = 'finished';
  clearHighlights();
  updateHUD();
};

function endGame(winner, reason) {
  D.gamePhase = 'finished';
  D._postGameReview = true;
  clearHighlights();
  const evalWrap = document.getElementById('eval-bar-wrap');
  if (evalWrap) evalWrap.style.display = '';
  _drawEvalGraph();
  const banner = document.getElementById('result-banner');
  let text;
  if (!winner) {
    text = reason === 'agreement' ? 'Draw by agreement' : 'Draw by repetition';
  } else {
    const name = winner === 'red' ? 'Red' : 'Black';
    const how = reason === 'kingCapture' ? 'captured the king'
              : reason === 'castle'      ? 'reached the castle'
              : reason === 'resign'      ? 'wins by resignation'
              :                           'seized the fort';
    text = `${name} wins — ${how}`;
  }
  banner.innerHTML = `<span>${text}</span><button class="banner-close" onclick="this.parentElement.style.display='none'" title="Dismiss">✕</button>`;
  banner.style.display = 'block';
}

function updateHUD(thinking = false) {
  if (!D.board) return;
  const side = D.board.sideToMove === 'red' ? 'Red' : 'Black';
  const el = document.getElementById('turn-label');
  if (D.analysisMode) { el.textContent = 'Analysis'; el.classList.remove('thinking'); return; }
  if (D.gamePhase !== 'playing') { el.textContent = ''; return; }
  el.textContent = thinking ? `${side} is thinking…` : `${side}'s turn`;
  el.classList.toggle('thinking', thinking);
}

D.setThinking = function(on) { updateHUD(on); };

D.evalHistory = []; // { fromRed: number } per half-move matching boardHistory indices

D.showEval = function(score, depth, side) {
  const evalLine = document.getElementById('eval-line');
  const bar = document.getElementById('eval-bar-black');
  if (score === null) {
    if (evalLine) evalLine.textContent = '';
    if (bar) bar.style.height = '50%';
    return;
  }
  const MATE = 100000;
  const fromRed = side === 'red' ? score : -score;
  let scoreStr;
  if (Math.abs(score) >= MATE - 200) {
    const movesToMate = Math.ceil((MATE - Math.abs(score)) / 2);
    scoreStr = fromRed > 0 ? `#${movesToMate}` : `-#${movesToMate}`;
  } else {
    const cp = (fromRed / 100).toFixed(2);
    scoreStr = fromRed >= 0 ? `+${cp}` : `${cp}`;
  }
  if (evalLine) evalLine.textContent = `${scoreStr}  depth ${depth}`;
  if (bar) {
    const MAX_CP = 800;
    const pct = Math.max(0, Math.min(1, (fromRed + MAX_CP) / (2 * MAX_CP)));
    // bar fills from top = black's share; remainder = red's share
    bar.style.height = `${((1 - pct) * 100).toFixed(1)}%`;
  }
  const idx = D.boardHistory ? D.boardHistory.length - 1 : 0;
  D.evalHistory[idx] = fromRed;
  _drawEvalGraph();
};

function _drawEvalGraph() {
  const svg = document.getElementById('eval-graph');
  const section = document.getElementById('eval-graph-section');
  if (!svg || !section) return;
  if (!D._postGameReview) return;
  const pts = D.evalHistory.filter(v => v !== undefined);
  if (pts.length < 2) { section.style.display = 'none'; return; }
  section.style.display = '';

  const W = svg.clientWidth || 192, H = 44;
  const MAX_CP = 800, MID = H / 2;
  const xs = pts.map((_, i) => (i / (pts.length - 1)) * W);
  const ys = pts.map(v => MID - Math.max(-MAX_CP, Math.min(MAX_CP, v)) / MAX_CP * MID);

  // Midline
  let d = `M 0 ${MID} L ${W} ${MID}`;
  // Score line
  const line = pts.map((_, i) => `${i === 0 ? 'M' : 'L'} ${xs[i].toFixed(1)} ${ys[i].toFixed(1)}`).join(' ');
  // Fill area
  const fill = line + ` L ${xs[xs.length-1].toFixed(1)} ${MID} L 0 ${MID} Z`;

  svg.innerHTML = `
    <defs>
      <linearGradient id="eg-grad" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stop-color="#b83030" stop-opacity="0.35"/>
        <stop offset="50%" stop-color="#b83030" stop-opacity="0.1"/>
        <stop offset="50%" stop-color="#171410" stop-opacity="0.1"/>
        <stop offset="100%" stop-color="#171410" stop-opacity="0.35"/>
      </linearGradient>
    </defs>
    <path d="${fill}" fill="url(#eg-grad)" stroke="none"/>
    <path d="M 0 ${MID} L ${W} ${MID}" stroke="rgba(255,255,255,0.08)" stroke-width="1" fill="none"/>
    <path d="${line}" stroke="#8b6f47" stroke-width="1.5" fill="none" stroke-linejoin="round" stroke-linecap="round"/>
  `;
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

function scheduleAI() {
  if (typeof D.triggerAIIfNeeded === 'function') D.triggerAIIfNeeded();
}

// --- Move list ---
function updateMoveList() {
  const el = document.getElementById('move-list');
  if (!el) return;
  const moves = D.moveHistory;
  if (!moves.length) { el.innerHTML = ''; return; }
  // viewIndex: null = live (highlight last), number = highlight that half-move
  const activeHalf = D.viewIndex !== null ? D.viewIndex - 1 : moves.length - 1;
  let html = '';
  for (let i = 0; i < moves.length; i += 2) {
    const num = Math.floor(i / 2) + 1;
    const redN = moves[i]?.notation ?? '';
    const blkN = moves[i + 1]?.notation ?? '';
    const hiR = i === activeHalf ? ' ml-active' : '';
    const hiB = i + 1 === activeHalf ? ' ml-active' : '';
    html += `<tr>` +
      `<td class="ml-num">${num}.</td>` +
      `<td class="ml-red${hiR}" onclick="D.navTo(${i + 1})">${redN}</td>` +
      `<td class="ml-black${hiB}" onclick="D.navTo(${i + 2})">${blkN}</td>` +
      `</tr>`;
  }
  el.innerHTML = html;
  // Scroll to keep active row visible
  const activeEl = el.querySelector('.ml-active');
  if (activeEl) activeEl.scrollIntoView({ block: 'nearest' });
  else el.parentElement.scrollTop = el.parentElement.scrollHeight;
}

// --- Captured pieces ---
const PIECE_LABELS = {
  king:'K', berserker:'Be', spearman:'Sp', bowman:'Bo',
  elf:'El', wolf:'Wo', dwarf:'Dw', hunter:'Hu', skjolding:'Sk',
};
function updateCaptured() {
  const rEl = document.getElementById('cap-red');
  const bEl = document.getElementById('cap-black');
  if (rEl) rEl.textContent = D.capturedRed.map(t => PIECE_LABELS[t] || t).join(' ');
  if (bEl) bEl.textContent = D.capturedBlack.map(t => PIECE_LABELS[t] || t).join(' ');
}

D.resign = function() {
  if (D.gamePhase !== 'playing') return;
  const loser = D.board.sideToMove;
  endGame(loser === 'red' ? 'black' : 'red', 'resign');
};

D.offerDraw = function() {
  if (D.gamePhase !== 'playing') return;
  const humanSide = D.board.sideToMove;
  const oppSetup = humanSide === 'red' ? D.blackSetup : D.redSetup;
  const humanSetup = humanSide === 'red' ? D.redSetup : D.blackSetup;
  if (humanSetup.kind !== 'human') return; // only human can offer

  if (oppSetup.kind === 'human') {
    // Human vs human: ask the other player
    if (window.confirm('Accept draw?')) endGame(null, 'agreement');
  } else {
    // Human vs AI: AI accepts if it's not clearly winning (eval ≤ +80 from AI's pov)
    const aiSide = humanSide === 'red' ? 'black' : 'red';
    let aiScore = 0;
    if (D.HR && D.HR.evaluate) aiScore = D.HR.evaluate(D.board, aiSide);
    if (aiScore <= 80) {
      endGame(null, 'agreement');
    } else {
      flashStatus('Draw declined');
    }
  }
};

function flashStatus(msg) {
  const el = document.getElementById('turn-label');
  const prev = el.textContent;
  el.textContent = msg;
  el.style.color = 'var(--muted)';
  setTimeout(() => { el.textContent = prev; el.style.color = ''; }, 2000);
}

// --- Save / Load ---
const _ipc = typeof require !== 'undefined' ? require('electron').ipcRenderer : null;

D.saveGame = async function() {
  if (!D.moveHistory.length) return;
  const lines = [
    'DROTT',
    `Red: ${D.redSetup.kind}`,
    `Black: ${D.blackSetup.kind}`,
    '',
  ];
  for (let i = 0; i < D.moveHistory.length; i += 2) {
    const num = Math.floor(i / 2) + 1;
    const red = D.moveHistory[i].notation;
    const blk = D.moveHistory[i + 1] ? D.moveHistory[i + 1].notation : '';
    lines.push(blk ? `${num}. ${red}  ${blk}` : `${num}. ${red}`);
  }
  if (_ipc) await _ipc.invoke('drott-save', lines.join('\n') + '\n');
};

D.loadGame = async function() {
  if (!_ipc) return;
  const res = await _ipc.invoke('drott-open');
  if (!res.ok) return;

  const tokens = [...res.content.matchAll(/[A-I][1-9][x\-][A-I][1-9]/g)].map(m => m[0]);
  if (!tokens.length) { alert('No moves found in file.'); return; }

  D.startGame();
  const COLS = 'ABCDEFGHI';
  for (const tok of tokens) {
    const fc = COLS.indexOf(tok[0]), fr = parseInt(tok[1]) - 1;
    const tc = COLS.indexOf(tok[3]), tr = parseInt(tok[4]) - 1;
    const legal = D.legalMoves(D.board);
    const match = legal.find(([f, t]) => f[0]===fc && f[1]===fr && t[0]===tc && t[1]===tr);
    if (!match) { alert(`Illegal move in file: ${tok}`); return; }
    executeMove(match);
  }
};

window.addEventListener('DOMContentLoaded', () => {
  initBoard();
  D.newGame(); // show start position in setup state; user clicks Start when ready
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
D.executeMove     = executeMove;
D.updateHUD       = updateHUD;
D.updateMoveList  = updateMoveList;
D.updateCaptured  = updateCaptured;
D.checkPendingWin = checkPendingWin;
D.SQ = SQ;

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { colRowToXY, SQ };
}
})();
