// hud.js — HUD display, move list, eval bar, eval graph, captured pieces
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

D.evalHistory = [];

const PIECE_LABELS = {
  king:'K', berserker:'Be', spearman:'Sp', bowman:'Bo',
  elf:'El', wolf:'Wo', dwarf:'Dw', hunter:'Hu', skjolding:'Sk',
};

function show(id, visible) {
  const el = document.getElementById(id);
  if (el) el.style.display = visible ? '' : 'none';
}

function updateButtons() {
  const phase = D.gamePhase;
  show('start-btn',  phase === 'setup');
  show('new-game-btn', phase === 'finished');
  show('resign-btn', phase === 'playing');
  show('draw-btn',   phase === 'playing');
  show('abort-btn',  phase === 'playing');
}

function updateHUD(thinking = false) {
  if (!D.board) return;
  updateButtons();
  const side = D.board.sideToMove === 'red' ? 'Red' : 'Black';
  const el = document.getElementById('turn-label');
  if (D.analysisMode) { el.textContent = 'Analysis'; el.classList.remove('thinking'); return; }
  if (D.gamePhase !== 'playing') { el.textContent = ''; return; }
  el.textContent = thinking ? `${side} is thinking…` : `${side}'s turn`;
  el.classList.toggle('thinking', thinking);
}

D.setThinking = function(on) { updateHUD(on); };
D.updateHUD   = updateHUD;

function updateMoveList() {
  const el = document.getElementById('move-list');
  if (!el) return;
  const moves = D.moveHistory;
  if (!moves.length) { el.innerHTML = ''; return; }
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
  const activeEl = el.querySelector('.ml-active');
  if (activeEl) activeEl.scrollIntoView({ block: 'nearest' });
  else el.parentElement.scrollTop = el.parentElement.scrollHeight;
}

D.updateMoveList = updateMoveList;

function updateCaptured() {
  const rEl = document.getElementById('cap-red');
  const bEl = document.getElementById('cap-black');
  if (rEl) rEl.textContent = D.capturedRed.map(t => PIECE_LABELS[t] || t).join(' ');
  if (bEl) bEl.textContent = D.capturedBlack.map(t => PIECE_LABELS[t] || t).join(' ');
}

D.updateCaptured = updateCaptured;

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
    bar.style.height = `${((1 - pct) * 100).toFixed(1)}%`;
  }
  const idx = D.boardHistory ? D.boardHistory.length - 1 : 0;
  D.evalHistory[idx] = fromRed;
  D.drawEvalGraph();
};

function _evalAtIndex(idx) {
  if (!D.evalHistory) return undefined;
  for (let i = idx; i >= 0; i--) {
    if (D.evalHistory[i] !== undefined) return D.evalHistory[i];
  }
  return undefined;
}

D.syncEvalBar = function(viewIdx) {
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

  const line = pts.map((_, i) => `${i === 0 ? 'M' : 'L'} ${xs[i].toFixed(1)} ${ys[i].toFixed(1)}`).join(' ');
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

D.drawEvalGraph = _drawEvalGraph;

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {};
}
})();
