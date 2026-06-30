// sandbox.js — "Experiment" board editor + rules-arbitrated playground.
//
// SAFETY: fully self-contained. Keeps its OWN board state; never reads or writes
// D.board / D.gamePhase / live-game state. For arbitration it only CALLS pure
// engine functions (D.legalMoves / D.applyMove / D.staticOutcome) and, for the
// optional opponent, the EXISTING 'hr-search' IPC. It modifies nothing else.
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

const NS = 'http://www.w3.org/2000/svg';
const N = 9, CELL = 60, PX = CELL * N;
const HR_THINK = 5;        // "Play vs Herringbone" defaults to Herringbone 5s
const HUMAN_SIDE = 'red';  // you play Red; Herringbone plays Black
const AI_SIDE = 'black';

const _ipc = (typeof require !== 'undefined') ? require('electron').ipcRenderer : null;
const _fs   = typeof require !== 'undefined' ? require('fs')   : null;
const _path = typeof require !== 'undefined' ? require('path') : null;
const _base = typeof __dirname !== 'undefined' ? __dirname : '.';
const _uriCache = {};
function pieceURI(type, side) {
  const key = `${type}-${side}`;
  if (_uriCache[key]) return _uriCache[key];
  if (!_fs) return '';
  let raw;
  try { raw = _fs.readFileSync(_path.join(_base, 'assets', 'pieces', `${type}.svg`), 'utf8'); }
  catch (_) { return ''; }
  const color = side === 'red' ? '#B83030' : '#171410';
  raw = raw.replace(/fill="black"/g, `fill="${color}"`).replace(/fill='black'/g, `fill='${color}'`);
  _uriCache[key] = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(raw);
  return _uriCache[key];
}

const COL = { normal: '#EDE4CC', fort: '#C0A878', zone: '#E4D8B0', castle: '#C8A030' };
function cat(col, row) {
  if (col === 4 && row === 4) return 'castle';
  if (Math.abs(col - 4) <= 1 && Math.abs(row - 4) <= 1) return 'zone';
  if (col === 4 && (row === 2 || row === 6)) return 'zone';
  if (row === 4 && (col === 2 || col === 6)) return 'zone';
  if (D.RED_FORT   && D.RED_FORT.has(`${col},${row}`))   return 'fort';
  if (D.BLACK_FORT && D.BLACK_FORT.has(`${col},${row}`)) return 'fort';
  return 'normal';
}

const PIECE_ORDER = ['king', 'skjolding', 'spearman', 'bowman', 'berserker', 'elf', 'wolf', 'dwarf', 'hunter'];
const NAME = {
  king: 'King', skjolding: 'Skjolding', spearman: 'Spearman', bowman: 'Bowman',
  berserker: 'Berserker', elf: 'The Sword', wolf: 'Wolf', dwarf: 'The Axe', hunter: 'Hunter',
};

// --- Local state (never the live game) ---
function emptyBoard() {
  return { squares: new Array(81).fill(null), sideToMove: 'red', winner: null, winReason: null };
}
let sb = null;
let svg, pieceLayer, hlLayer, built = false, wired = false;
let _hrGen = 0;            // bumped on pause/close so stale HR results are ignored

// --- Drag state ---
let _drag     = null;   // active drag payload
let _preClick = null;   // { col, row, startX, startY } — pending click before drag threshold

function _sbRect() { return svg ? svg.getBoundingClientRect() : null; }

function _clientToSquare(clientX, clientY) {
  const r = _sbRect(); if (!r) return null;
  const lx = clientX - r.left, ly = clientY - r.top;
  let c = Math.floor(lx / CELL), row = 8 - Math.floor(ly / CELL);
  if (sb.flipped) { c = 8 - c; row = 8 - row; }
  if (c < 0 || c > 8 || row < 0 || row > 8) return null;
  return [c, row];
}

function _makeGhost(type, side) {
  const ghost = document.createElement('img');
  ghost.src = pieceURI(type, side);
  const sz = CELL * 0.9;
  Object.assign(ghost.style, {
    position: 'fixed', width: `${sz}px`, height: `${sz}px`,
    pointerEvents: 'none', opacity: '0.85', zIndex: '9999',
    transform: 'translate(-50%,-50%)', userSelect: 'none',
  });
  document.body.appendChild(ghost);
  return ghost;
}

function _moveGhost(e) {
  if (_drag?.ghost) { _drag.ghost.style.left = `${e.clientX}px`; _drag.ghost.style.top = `${e.clientY}px`; }
}

function _startBoardPieceDrag(col, row, e) {
  const piece = sb.board.squares[col + row * N];
  if (sb.mode === 'play') {
    if (!piece || piece.side !== sb.board.sideToMove) return;
    if (sb.opponent === 'herringbone' && sb.board.sideToMove === AI_SIDE) return;
    sb.sel = [col, row];
    sb.valid = D.legalMoves(sb.board).filter(m => m[0][0] === col && m[0][1] === row);
    renderHighlights();
    _drag = { kind: 'play', type: piece.type, side: piece.side, fromCol: col, fromRow: row,
              ghost: _makeGhost(piece.type, piece.side) };
  } else {
    if (!piece) return;
    sb.sel = [col, row]; renderHighlights();
    _drag = { kind: 'board', type: piece.type, side: piece.side, fromCol: col, fromRow: row,
              ghost: _makeGhost(piece.type, piece.side) };
  }
  _moveGhost(e);
}

function _startPaletteDrag(type, side, e) {
  if (sb.mode !== 'edit') return;
  sb.tool = 'place'; sb.pal = { type, side }; updateControls();
  _drag = { kind: 'palette', type, side, fromCol: null, fromRow: null,
            ghost: _makeGhost(type, side) };
  _moveGhost(e);
}

function _endDrag(e) {
  if (!_drag) return;
  _drag.ghost.remove();
  const target = _clientToSquare(e.clientX, e.clientY);
  const { kind, type, side, fromCol, fromRow } = _drag;
  _drag = null;
  sb.sel = null; sb.valid = [];

  if (!target) { renderAll(); return; }
  const [tc, tr] = target;

  if (kind === 'palette') {
    sb.board.squares[tc + tr * N] = { type, side, col: tc, row: tr };
  } else if (kind === 'board') {
    const fi = fromCol + fromRow * N, ti = tc + tr * N;
    if (fi !== ti) {
      sb.board.squares[ti] = { type, side, col: tc, row: tr };
      sb.board.squares[fi] = null;
    }
  } else if (kind === 'play') {
    const mv = sb.valid.find(m => m[1][0] === tc && m[1][1] === tr);
    if (mv) { doMove(mv); return; }
  }
  renderAll();
}

function _docMouseMove(e) {
  if (_preClick) {
    const dx = e.clientX - _preClick.startX, dy = e.clientY - _preClick.startY;
    if (Math.abs(dx) > 4 || Math.abs(dy) > 4) {
      const { col, row } = _preClick; _preClick = null;
      _startBoardPieceDrag(col, row, e);
    }
  }
  _moveGhost(e);
}

function _docMouseUp(e) {
  document.removeEventListener('mousemove', _docMouseMove);
  document.removeEventListener('mouseup', _docMouseUp);
  if (_drag) {
    _endDrag(e);
  } else if (_preClick) {
    onCell(_preClick.col, _preClick.row);
  }
  _preClick = null;
  if (_drag) { _drag.ghost.remove(); _drag = null; }
}

function el(tag) { return document.createElementNS(NS, tag); }
function sa(e, a) { for (const [k, v] of Object.entries(a)) e.setAttribute(k, v); return e; }

// Display transform (honours board flip)
function dispTL(col, row) {
  const c = sb.flipped ? 8 - col : col;
  const r = sb.flipped ? 8 - row : row;
  return [c * CELL, (8 - r) * CELL];
}
function dispC(col, row) { const [x, y] = dispTL(col, row); return [x + CELL / 2, y + CELL / 2]; }

function buildBoard() {
  const container = document.getElementById('sandbox-board');
  if (!container) return;
  container.innerHTML = '';
  svg = sa(el('svg'), { width: PX, height: PX, viewBox: `0 0 ${PX} ${PX}`, class: 'sandbox-svg' });
  container.appendChild(svg);

  const bg = el('g');
  svg.appendChild(bg);
  bg.appendChild(sa(el('rect'), { width: PX, height: PX, fill: '#2a2010' }));
  const G = 1.4, RX = 9;
  for (let row = 0; row < N; row++) {
    for (let col = 0; col < N; col++) {
      const [tx, ty] = dispTL(col, row);
      bg.appendChild(sa(el('rect'), {
        x: tx + G, y: ty + G, width: CELL - G * 2, height: CELL - G * 2, fill: COL[cat(col, row)], rx: RX,
      }));
    }
  }
  const [ccx, ccy] = dispC(4, 4);
  bg.appendChild(sa(el('circle'), { cx: ccx, cy: ccy, r: 8, fill: 'none', stroke: 'rgba(80,50,0,0.5)', 'stroke-width': 1.8 }));

  hlLayer = el('g'); bg.appendChild(hlLayer);
  pieceLayer = el('g'); pieceLayer.style.pointerEvents = 'none'; bg.appendChild(pieceLayer);

  const clickLayer = el('g');
  for (let row = 0; row < N; row++) {
    for (let col = 0; col < N; col++) {
      const [tx, ty] = dispTL(col, row);
      const r = sa(el('rect'), { x: tx, y: ty, width: CELL, height: CELL, fill: 'transparent' });
      r.style.cursor = 'pointer';
      r.addEventListener('mousedown', e => {
        if (e.button !== 0) return;
        e.preventDefault();
        _preClick = { col, row, startX: e.clientX, startY: e.clientY };
        document.addEventListener('mousemove', _docMouseMove);
        document.addEventListener('mouseup', _docMouseUp);
      });
      clickLayer.appendChild(r);
    }
  }
  svg.appendChild(clickLayer);
  built = true;
}

function renderPieces() {
  while (pieceLayer.firstChild) pieceLayer.removeChild(pieceLayer.firstChild);
  const size = CELL * 0.8;
  for (const s of sb.board.squares) {
    if (!s) continue;
    const [x, y] = dispC(s.col, s.row);
    pieceLayer.appendChild(sa(el('image'), {
      href: pieceURI(s.type, s.side), x: x - size / 2, y: y - size / 2, width: size, height: size,
    }));
  }
}

function renderHighlights() {
  while (hlLayer.firstChild) hlLayer.removeChild(hlLayer.firstChild);
  if (!sb.sel) return;
  const [sc, sr] = sb.sel;
  const [tx, ty] = dispTL(sc, sr);
  hlLayer.appendChild(sa(el('rect'), {
    x: tx + 2, y: ty + 2, width: CELL - 4, height: CELL - 4,
    fill: 'rgba(255,220,0,0.18)', stroke: 'rgba(255,200,0,0.85)', 'stroke-width': 2.5, rx: 3,
  }));
  for (const m of sb.valid) {
    const [, to, isCap] = m;
    const [cx, cy] = dispC(to[0], to[1]);
    if (isCap) {
      hlLayer.appendChild(sa(el('circle'), { cx, cy, r: CELL * 0.38, fill: 'none', stroke: 'rgba(220,60,50,0.8)', 'stroke-width': 3 }));
    } else {
      hlLayer.appendChild(sa(el('circle'), { cx, cy, r: 9, fill: 'rgba(255,210,0,0.55)' }));
    }
  }
}

function renderAll() { if (!built) return; renderPieces(); renderHighlights(); updateControls(); }

// --- Interaction ---
function onCell(col, row) {
  if (sb.mode === 'play') handlePlayClick(col, row);
  else handleEditClick(col, row);
  renderAll();
}

function handleEditClick(col, row) {
  const idx = col + row * N;
  if (sb.tool === 'delete') { sb.board.squares[idx] = null; sb.sel = null; return; }
  if (sb.tool === 'move') {
    if (sb.sel) {
      const [fc, fr] = sb.sel, fi = fc + fr * N, p = sb.board.squares[fi];
      if (p && !(fc === col && fr === row)) {
        sb.board.squares[idx] = { type: p.type, side: p.side, col, row };
        sb.board.squares[fi] = null;
      }
      sb.sel = null;
    } else if (sb.board.squares[idx]) {
      sb.sel = [col, row];
    }
    return;
  }
  // place
  if (!sb.pal) return;
  sb.board.squares[idx] = { type: sb.pal.type, side: sb.pal.side, col, row };
}

function handlePlayClick(col, row) {
  if (sb.board.winner) return;
  if (sb.opponent === 'herringbone' && sb.board.sideToMove === AI_SIDE) return; // HR's turn
  const sq = sb.board.squares[col + row * N];
  if (sb.sel) {
    const mv = sb.valid.find(m => m[1][0] === col && m[1][1] === row);
    if (mv) { doMove(mv); return; }
    if (sq && sq.side === sb.board.sideToMove) { selectPlay(col, row); return; }
    sb.sel = null; sb.valid = [];
    return;
  }
  if (sq && sq.side === sb.board.sideToMove) selectPlay(col, row);
}

function selectPlay(col, row) {
  sb.sel = [col, row];
  sb.valid = D.legalMoves(sb.board).filter(m => m[0][0] === col && m[0][1] === row);
}

function doMove(mv) {
  sb.board = D.applyMove(sb.board, mv);   // pure engine call; sets winner if decided
  sb.sel = null; sb.valid = [];
  if (sb.opponent === 'herringbone' && !sb.board.winner && sb.board.sideToMove === AI_SIDE) {
    setTimeout(triggerHR, 80);
  }
}

// --- Herringbone opponent (reuses existing hr-search IPC; engine untouched) ---
function triggerHR() {
  if (sb.mode !== 'play' || sb.opponent !== 'herringbone' || sb.board.winner) return;
  if (sb.board.sideToMove !== AI_SIDE || !_ipc) return;
  const myGen = ++_hrGen;
  setStatus('Herringbone is thinking…', 'thinking');
  _ipc.invoke('hr-search', { board: JSON.parse(JSON.stringify(sb.board)), thinkTime: HR_THINK })
    .then(res => {
      if (myGen !== _hrGen) return;                  // paused / returned / superseded
      if (sb.mode !== 'play' || sb.opponent !== 'herringbone') return;
      if (sb.board.winner || sb.board.sideToMove !== AI_SIDE) return;
      if (res && res.move) {
        sb.board = D.applyMove(sb.board, res.move);
        sb.sel = null; sb.valid = [];
        renderAll();
      } else { updateControls(); }
    })
    .catch(() => {});
}
function abortHR() { _hrGen++; if (_ipc) { try { _ipc.invoke('hr-abort'); } catch (_) {} } }

// --- Controls ---
function countKings(side) {
  let n = 0;
  for (const s of sb.board.squares) if (s && s.type === 'king' && s.side === side) n++;
  return n;
}
function kingsOk() { return countKings('red') >= 1 && countKings('black') >= 1; }

function setStatus(msg, kind) {
  const s = document.getElementById('sb-status');
  if (!s) return;
  s.textContent = msg || '';
  s.className = 'sandbox-status' + (kind ? ' ' + kind : '');
}

function resultText(winner, reason) {
  if (!winner) return 'Draw';
  const name = winner === 'red' ? 'Red' : 'Black';
  const how = reason === 'kingCapture' ? 'captured the King'
            : reason === 'castle'      ? 'reached the Castle'
            :                            'seized the Fort';
  return `${name} wins — ${how}`;
}

function enterPlay(opponent) {
  if (!kingsOk()) { setStatus('Each side needs at least one King before you can play.', 'warn'); return; }
  sb.mode = 'play';
  sb.opponent = opponent;
  sb.sel = null; sb.valid = [];
  const [w, r] = D.staticOutcome(sb.board);
  if (w) sb.board = { ...sb.board, winner: w, winReason: r };
  renderAll();
  if (opponent === 'herringbone' && !sb.board.winner && sb.board.sideToMove === AI_SIDE) {
    setTimeout(triggerHR, 200);
  }
}

function pause() {
  abortHR();
  sb.mode = 'edit';
  sb.opponent = null;
  sb.board = { ...sb.board, winner: null, winReason: null };
  sb.sel = null; sb.valid = [];
  renderAll();
}

function updateControls() {
  const playing = sb.mode === 'play';
  const panel = document.getElementById('sandbox-panel');
  if (panel) panel.classList.toggle('sb-playing', playing);

  const pp = document.getElementById('sb-playpause');
  if (pp) { pp.textContent = playing ? '❚❚  Pause' : '▶  Play'; pp.classList.toggle('playing', playing); }
  const phr = document.getElementById('sb-play-hr');
  if (phr) phr.style.display = playing ? 'none' : '';

  for (const side of ['red', 'black']) {
    const b = document.getElementById(`sb-side-${side}`);
    if (b) b.classList.toggle('active', sb.board.sideToMove === side);
  }
  document.querySelectorAll('.sb-swatch').forEach(s => {
    s.classList.toggle('active', sb.tool === 'place' && sb.pal &&
      s.dataset.type === sb.pal.type && s.dataset.side === sb.pal.side);
  });
  document.querySelectorAll('.sb-hand').forEach(b => b.classList.toggle('active', sb.tool === 'move'));
  document.querySelectorAll('.sb-trash').forEach(b => b.classList.toggle('active', sb.tool === 'delete'));

  if (sb.board.winner) {
    setStatus(resultText(sb.board.winner, sb.board.winReason), 'win');
  } else if (playing) {
    const turn = sb.board.sideToMove === 'red' ? 'Red' : 'Black';
    if (sb.opponent === 'herringbone' && sb.board.sideToMove === AI_SIDE) return; // keep "thinking…"
    setStatus(sb.opponent === 'herringbone'
      ? `Your move (Red) — Herringbone plays Black.`
      : `${turn} to move — pieces follow the rules.`, '');
  } else {
    setStatus('Edit mode — place pieces, pick who moves first, then press Play.', '');
  }
}

function setSide(side) { if (sb.mode === 'edit') { sb.board.sideToMove = side; renderAll(); } }
function clearBoard() { if (sb.mode !== 'edit') return; sb.board = emptyBoard(); sb.sel = null; renderAll(); }
function startPos()  { if (sb.mode !== 'edit') return; sb.board = D.makeStartBoard(); sb.sel = null; renderAll(); }
function flip()      { sb.flipped = !sb.flipped; buildBoard(); renderAll(); }

function selectPalette(type, side) { if (sb.mode !== 'edit') return; sb.tool = 'place'; sb.pal = { type, side }; updateControls(); }
function selectHand()  { if (sb.mode !== 'edit') return; sb.tool = 'move';   sb.pal = null; sb.sel = null; renderAll(); }
function selectTrash() { if (sb.mode !== 'edit') return; sb.tool = 'delete'; sb.pal = null; sb.sel = null; renderAll(); }

function buildPalette(side) {
  const row = document.getElementById(`sb-palette-${side}`);
  if (!row) return;
  const hand = `<button class="sb-tray-tool sb-hand" title="Move pieces freely">&#9995;</button>`;
  const trash = `<button class="sb-tray-tool sb-trash" title="Erase pieces">&#128465;</button>`;
  const swatches = PIECE_ORDER.map(type => `
    <button class="sb-swatch" data-type="${type}" data-side="${side}" title="${NAME[type]} (${side})">
      <img src="${pieceURI(type, side)}" alt="${NAME[type]}">
    </button>`).join('');
  row.innerHTML = hand + swatches + trash;
  row.querySelector('.sb-hand').addEventListener('click', selectHand);
  row.querySelector('.sb-trash').addEventListener('click', selectTrash);
  row.querySelectorAll('.sb-swatch').forEach(b => {
    b.addEventListener('click', () => selectPalette(b.dataset.type, b.dataset.side));
    b.addEventListener('mousedown', e => {
      if (e.button !== 0 || sb.mode !== 'edit') return;
      e.preventDefault();
      _startPaletteDrag(b.dataset.type, b.dataset.side, e);
      document.addEventListener('mousemove', _docMouseMove);
      document.addEventListener('mouseup', _docMouseUp);
    });
  });
}

function ensureBuilt() {
  if (built) return;
  buildBoard();
  buildPalette('black');
  buildPalette('red');
  if (!wired) {
    document.getElementById('sb-playpause').addEventListener('click', () => (sb.mode === 'play' ? pause() : enterPlay(null)));
    document.getElementById('sb-play-hr').addEventListener('click', () => enterPlay('herringbone'));
    document.getElementById('sb-flip').addEventListener('click', flip);
    document.getElementById('sb-clear').addEventListener('click', clearBoard);
    document.getElementById('sb-start').addEventListener('click', startPos);
    document.getElementById('sb-side-red').addEventListener('click', () => setSide('red'));
    document.getElementById('sb-side-black').addEventListener('click', () => setSide('black'));
    wired = true;
  }
}

function isOpen() {
  const p = document.getElementById('sandbox-panel');
  return p && p.style.display !== 'none';
}

D.openSandbox = function() {
  const panel = document.getElementById('sandbox-panel');
  const wrap  = document.getElementById('board-wrap');
  if (!panel || !wrap) return;
  if (!sb) sb = { board: D.makeStartBoard(), mode: 'edit', tool: 'move', pal: null, sel: null, valid: [], flipped: false, opponent: null };
  ensureBuilt();   // builds the board; needs sb to exist for the flip transform
  wrap.style.display = 'none';
  panel.style.display = 'flex';
  const btn = document.getElementById('open-sandbox-btn');
  if (btn) btn.innerHTML = '<span class="rules-open-icon">&#8617;</span> Return to Play';
  renderAll();
};

D.closeSandbox = function() {
  const panel = document.getElementById('sandbox-panel');
  const wrap  = document.getElementById('board-wrap');
  abortHR();
  if (panel) panel.style.display = 'none';
  if (wrap) wrap.style.display = '';
  const btn = document.getElementById('open-sandbox-btn');
  if (btn) btn.innerHTML = '<span class="rules-open-icon">&#9858;</span> Experiment';
};

D.toggleSandbox = function() { if (isOpen()) D.closeSandbox(); else D.openSandbox(); };

if (typeof module !== 'undefined' && module.exports) module.exports = {};
})();
