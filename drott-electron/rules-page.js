// rules-page.js — full-screen rules overlay with engine-generated movement diagrams.
// READ-ONLY consumer of the rules engine: it calls D.legalMoves on throwaway boards
// to draw each piece's reach. It never mutates game state or the rules code.
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

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

// --- Generate a piece's reachable squares via the real engine ---
// One red piece in the centre of an otherwise-empty board. Because the engine is
// the single source of truth, these diagrams can never drift from actual play.
function genMoves(type) {
  if (!D.legalMoves) return [];
  const squares = new Array(81).fill(null);
  const c = 4, r = 4;
  squares[c + r * 9] = { type, side: 'red', col: c, row: r };
  const board = { squares, sideToMove: 'red', winner: null, winReason: null };
  return D.legalMoves(board);
}

// --- Mini board SVG ---
function diagramSVG(type, opts) {
  opts = opts || {};
  const CELL = opts.cell || 21, N = 9, px = CELL * N;
  const moves = type ? genMoves(type) : [];
  const cream = '#EDE4CC', gold = '#C8A030', fortCol = '#C0A878';

  let cells = '';
  for (let row = 0; row < N; row++) {
    for (let col = 0; col < N; col++) {
      const x = col * CELL, y = (8 - row) * CELL;
      let fill = cream;
      if (opts.showForts && D.RED_FORT && D.RED_FORT.has(`${col},${row}`)) fill = fortCol;
      else if (opts.showForts && D.BLACK_FORT && D.BLACK_FORT.has(`${col},${row}`)) fill = fortCol;
      if (col === 4 && row === 4 && (opts.showCastle || type)) fill = gold;
      cells += `<rect x="${x}" y="${y}" width="${CELL}" height="${CELL}" fill="${fill}" stroke="rgba(120,80,30,0.20)" stroke-width="0.5"/>`;
    }
  }

  let dots = '';
  for (const m of moves) {
    const [tc, tr] = m[1];
    const cx = tc * CELL + CELL / 2, cy = (8 - tr) * CELL + CELL / 2;
    dots += `<circle cx="${cx}" cy="${cy}" r="${(CELL * 0.17).toFixed(1)}" fill="rgba(190,48,48,0.78)"/>`;
  }

  let piece = '';
  if (type) {
    const sz = CELL * 0.84;
    const px0 = 4 * CELL + (CELL - sz) / 2;
    const py0 = (8 - 4) * CELL + (CELL - sz) / 2;
    piece = `<image href="${pieceURI(type, 'red')}" x="${px0.toFixed(1)}" y="${py0.toFixed(1)}" width="${sz.toFixed(1)}" height="${sz.toFixed(1)}"/>`;
  }

  return `<svg viewBox="0 0 ${px} ${px}" class="rules-diagram" role="img">${cells}${dots}${piece}</svg>`;
}

// --- Win-conditions board: castle + both forts highlighted ---
function winBoardSVG() {
  const CELL = 21, N = 9, px = CELL * N;
  const cream = '#EDE4CC', gold = '#C8A030', fortCol = '#C0A878';
  let cells = '';
  for (let row = 0; row < N; row++) {
    for (let col = 0; col < N; col++) {
      const x = col * CELL, y = (8 - row) * CELL;
      let fill = cream;
      if (D.RED_FORT && D.RED_FORT.has(`${col},${row}`)) fill = fortCol;
      else if (D.BLACK_FORT && D.BLACK_FORT.has(`${col},${row}`)) fill = fortCol;
      if (col === 4 && row === 4) fill = gold;
      cells += `<rect x="${x}" y="${y}" width="${CELL}" height="${CELL}" fill="${fill}" stroke="rgba(120,80,30,0.20)" stroke-width="0.5"/>`;
    }
  }
  // Castle ring marker
  const [ccx, ccy] = [4 * CELL + CELL / 2, (8 - 4) * CELL + CELL / 2];
  const ring = `<circle cx="${ccx}" cy="${ccy}" r="${CELL * 0.32}" fill="none" stroke="rgba(80,50,0,0.55)" stroke-width="1.6"/>`;
  return `<svg viewBox="0 0 ${px} ${px}" class="rules-diagram rules-diagram-wide" role="img">${cells}${ring}</svg>`;
}

// --- Piece catalogue (display names match the engine's behaviour) ---
const PIECES = [
  { type: 'king', name: 'King', abbr: 'K',
    desc: 'Steps one square in any direction. A one-step diagonal is blocked when both squares between it and the King are occupied (shieldwall). Move your King onto the Castle to win — but it must survive to your next turn.' },
  { type: 'skjolding', name: 'Skjolding', abbr: 'V',
    desc: 'The shieldwall infantry. Leaps two squares straight forward (the square ahead must be clear), steps one square diagonally forward, or retreats one square straight back. Diagonally adjacent Skjoldings guard one another.' },
  { type: 'spearman', name: 'Spearman', abbr: 'Sp',
    desc: 'Long reach forward: one or two squares straight ahead and one or two squares diagonally forward, with a single step backward. Wide on the attack, narrow in retreat. Diagonal lunges are stopped by a shieldwall.' },
  { type: 'bowman', name: 'Bowman', abbr: 'Bw',
    desc: 'Fires down its lane: slides up to four squares straight forward until blocked, and shuffles one square to either side. No backward step — keep it supported.' },
  { type: 'berserker', name: 'Berserker', abbr: 'Bk',
    desc: 'Charges up to three squares straight forward, up to three squares in each forward diagonal lane (the lane must be clear to leap into it), and one square to either side. A relentless forward attacker.' },
  { type: 'elf', name: 'The Sword', abbr: 'Sw',
    desc: 'A heroic guardian of the King. Steps one square orthogonally in any direction, or slides up to four squares diagonally. The diagonal slide is stopped when two pieces wall off the corner it would pass through.' },
  { type: 'wolf', name: 'Wolf', abbr: 'Wo',
    desc: 'Ranges up to three squares along any rank or file, stopping at the first piece. Fast and far-reaching on open lines — ideal for seizing the flanks early.' },
  { type: 'dwarf', name: 'The Axe', abbr: 'Ax',
    desc: 'A heroic guardian of the King. Steps up to two squares orthogonally, leaps two squares diagonally, and makes a knight’s leap. Both leaps are blocked when pieces wall off the corner the Axe would cross.' },
  { type: 'hunter', name: 'Hunter', abbr: 'Hu',
    desc: 'Steps one square diagonally and makes a knight’s leap. The leap is illegal if a straight line from its square to the target crosses an occupied square — pieces set corner-to-corner also block it.' },
];

function buildContent() {
  const pieceCards = PIECES.map(p => `
    <div class="rules-piece-card">
      <div class="rules-piece-diagram">${diagramSVG(p.type)}</div>
      <div class="rules-piece-text">
        <div class="rules-piece-name">${p.name} <span class="rules-piece-abbr">${p.abbr}</span></div>
        <p>${p.desc}</p>
      </div>
    </div>`).join('');

  return `
    <div class="rules-doc-head">
      <h1>DROTT</h1>
      <p class="rules-doc-sub">The Norse Strategy Game — Complete Rules</p>
    </div>

    <section class="rules-doc-section rules-intro">
      <p>Drott is a game of two warbands clashing on a 9&times;9 field. Each side musters a King,
      a wall of Skjoldings, and a company of officers. There is no dice and no hidden information:
      everything you need to know is on the board.</p>
    </section>

    <section class="rules-doc-section">
      <h2>How to Win</h2>
      <div class="rules-win-grid">
        <div class="rules-win-board">${winBoardSVG()}</div>
        <ol class="rules-win-list">
          <li><b>Capture the King.</b> Land any piece on the enemy King and the game is yours at once.</li>
          <li><b>Take the Castle.</b> Move your King onto the central golden square and survive until your next turn — a standing threat your opponent must answer.</li>
          <li><b>Seize the Fort.</b> Hold at least one piece inside the enemy fort (the shaded home camps) while they hold none of their own.</li>
        </ol>
      </div>
    </section>

    <section class="rules-doc-section">
      <h2>Movement &amp; Capture</h2>
      <ul class="rules-bullets">
        <li>Most pieces <b>slide</b> in straight lines and cannot jump over another piece — the first piece they meet blocks the rest of the line.</li>
        <li>You <b>capture</b> by landing on an enemy piece. There is no separate capture move: any square a piece can reach, it can capture on.</li>
        <li>The <b>Axe</b> and <b>Hunter</b> make a knight’s leap. It is legal only if a straight line from their square to the target does not cross an occupied square — and two pieces set corner-to-corner also block the path.</li>
        <li><b>Shieldwall:</b> a one-step diagonal move is blocked when both of the orthogonal squares flanking it are occupied. Walls of Skjoldings use this to lock down ground.</li>
        <li>Pieces marked as moving <b>forward</b> advance toward the far side of the board. Diagrams below show a Red piece, which moves <b>upward</b>.</li>
      </ul>
    </section>

    <section class="rules-doc-section">
      <h2>The Pieces</h2>
      <p class="rules-note">Each diagram is drawn live by the game engine — the red dots are exactly the squares
      that piece can reach from the centre of an empty board.</p>
      <div class="rules-piece-grid">${pieceCards}</div>
    </section>

    <section class="rules-doc-section">
      <h2>Strategy</h2>
      <ul class="rules-bullets">
        <li>Hold the centre with Spearman, Bowman and Berserker to bar the enemy King’s road to the Castle.</li>
        <li>Develop the Wolf and Hunter to the flanks early; bring the Sword and Axe up behind them.</li>
        <li>The King’s march to the Castle is a winning threat in itself — but never forget to garrison your own Fort.</li>
        <li>With a material edge, press both flanks at once. The defender cannot hold everywhere.</li>
      </ul>
    </section>`;
}

let _built = false;
function ensureBuilt() {
  if (_built) return;
  const body = document.getElementById('rules-overlay-body');
  if (!body) return;
  body.innerHTML = buildContent();
  _built = true;
}

D.openRules = function() {
  const ov = document.getElementById('rules-overlay');
  if (!ov) return;
  ensureBuilt();
  ov.style.display = 'flex';
  const modal = document.getElementById('rules-overlay-modal');
  if (modal) modal.scrollTop = 0;
};

D.closeRules = function() {
  const ov = document.getElementById('rules-overlay');
  if (ov) ov.style.display = 'none';
};

document.addEventListener('keydown', e => {
  if (e.key === 'Escape') {
    const ov = document.getElementById('rules-overlay');
    if (ov && ov.style.display !== 'none') D.closeRules();
  }
});

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { genMoves };
}
})();
