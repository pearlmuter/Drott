// game.js — game state machine: moves, game flow, resign, draw, save/load
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

// --- State ---
D.board         = null;
D.selected      = null;
D.validMoves    = [];
D.repCounts     = {};
D.gamePhase     = 'setup';
D.moveHistory   = [];
D.capturedRed   = [];
D.capturedBlack = [];
D.lastMove      = null;
D.boardHistory  = [];
D.viewIndex     = null;
D.showAttackMap = false;
D.analysisMode  = false;
D.autoFlip      = false;

D.redSetup   = { kind: 'human', thinkTime: 5, model: 'astrid_v1', iterations: 100 };
D.blackSetup = { kind: 'human', thinkTime: 5, model: 'astrid_v1', iterations: 100 };

const COLS = 'ABCDEFGHI';

function moveNotation(move) {
  const [[fc, fr], [tc, tr], cap] = move;
  return `${COLS[fc]}${fr + 1}${cap ? 'x' : '-'}${COLS[tc]}${tr + 1}`;
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
  if (move[2]) {
    const [, to] = move;
    const cap = D.board.squares[to[0] + to[1] * D.N];
    if (cap) (side === 'red' ? D.capturedRed : D.capturedBlack).push(cap.type);
  }
  if (D.playSound) D.playSound(move[2] ? 'capture' : 'move');
  D.moveHistory.push({ notation: moveNotation(move), side });
  D.lastMove = [move[0], move[1]];
  D.board = D.applyMove(D.board, move);
  D.boardHistory.push(D.board);
  D.viewIndex = null;
  const key = D.repetitionKey(D.board).toString();
  D.repCounts[key] = (D.repCounts[key] || 0) + 1;
  D.selected = null; D.validMoves = [];
  D.renderPieces(); D.showHighlights(); D.updateHUD(); D.updateMoveList(); D.updateCaptured();
  if (D.board.winner) {
    if (D.board.winReason === 'kingCapture') {
      endGame(D.board.winner, D.board.winReason); return;
    }
    // castle/fort: defer — win fires at the START of the winner's next turn
    D._pendingWin = { winner: D.board.winner, reason: D.board.winReason };
    D.board = { ...D.board, winner: null, winReason: null };
  }
  if (D.repCounts[key] >= 3) { endGame(null, 'repetition'); return; }
  // Auto-flip for hotseat: keep the active player's pieces at the bottom
  if (D.autoFlip && D.redSetup.kind === 'human' && D.blackSetup.kind === 'human' && D.flipBoard) {
    const needFlipped = D.board.sideToMove === 'black';
    if (D.flipped !== needFlipped) D.flipBoard();
  }
  if (D.triggerAIIfNeeded) D.triggerAIIfNeeded();
}

function endGame(winner, reason) {
  D.gamePhase = 'finished';
  D._postGameReview = true;
  D.clearHighlights();
  const evalWrap = document.getElementById('eval-bar-wrap');
  if (evalWrap) evalWrap.style.display = '';
  D.drawEvalGraph();
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

D.newGame = function() {
  _resetBoard();
  D.gamePhase = 'setup';
  D.clearHighlights(); D.renderPieces(); D.updateHUD(); D.updateMoveList(); D.updateCaptured();
};

D.startGame = function() {
  _resetBoard();
  D.gamePhase = 'playing';
  // Auto-flip on: start from Red's perspective (Red always moves first)
  if (D.autoFlip && D.flipped && D.flipBoard) D.flipBoard();
  D.clearHighlights(); D.renderPieces(); D.updateHUD(); D.updateMoveList(); D.updateCaptured();
  if (D.triggerAIIfNeeded) D.triggerAIIfNeeded();
};

D.toggleAutoFlip = function() {
  D.autoFlip = !D.autoFlip;
  const btn = document.getElementById('auto-flip-btn');
  if (btn) btn.classList.toggle('active', D.autoFlip);
  // Snap to correct orientation immediately if mid-game hotseat
  if (D.autoFlip && D.gamePhase === 'playing' && D.flipBoard &&
      D.redSetup.kind === 'human' && D.blackSetup.kind === 'human') {
    const needFlipped = D.board && D.board.sideToMove === 'black';
    if (D.flipped !== needFlipped) D.flipBoard();
  }
};

D.abortGame = function() {
  if (D.gamePhase !== 'playing') return;
  if (D.terminateHRWorker) D.terminateHRWorker();
  D.isAILocked = false;
  D._pendingWin = null;
  D.gamePhase = 'finished';
  D.clearHighlights();
  D.updateHUD();
};

D.resign = function() {
  if (D.gamePhase !== 'playing') return;
  const loser = D.board.sideToMove;
  endGame(loser === 'red' ? 'black' : 'red', 'resign');
};

D.offerDraw = function() {
  if (D.gamePhase !== 'playing') return;
  const humanSide = D.board.sideToMove;
  const oppSetup   = humanSide === 'red' ? D.blackSetup : D.redSetup;
  const humanSetup = humanSide === 'red' ? D.redSetup   : D.blackSetup;
  if (humanSetup.kind !== 'human') return;
  if (oppSetup.kind === 'human') {
    if (window.confirm('Accept draw?')) endGame(null, 'agreement');
  } else {
    const aiSide = humanSide === 'red' ? 'black' : 'red';
    let aiScore = 0;
    if (D.HR && D.HR.evaluate) aiScore = D.HR.evaluate(D.board, aiSide);
    if (aiScore <= 80) {
      endGame(null, 'agreement');
    } else {
      _flashStatus('Draw declined');
    }
  }
};

function _flashStatus(msg) {
  const el = document.getElementById('turn-label');
  const prev = el.textContent;
  el.textContent = msg;
  el.style.color = 'var(--muted)';
  setTimeout(() => { el.textContent = prev; el.style.color = ''; }, 2000);
}

const _ipc = typeof require !== 'undefined' ? require('electron').ipcRenderer : null;

const _clip = typeof require !== 'undefined' ? require('electron').clipboard : null;

D.copyMoves = function() {
  if (!D.moveHistory.length) return;
  const lines = [];
  for (let i = 0; i < D.moveHistory.length; i += 2) {
    const num = Math.floor(i / 2) + 1;
    const red = D.moveHistory[i].notation;
    const blk = D.moveHistory[i + 1] ? D.moveHistory[i + 1].notation : '';
    lines.push(blk ? `${num}. ${red}  ${blk}` : `${num}. ${red}`);
  }
  if (_clip) _clip.writeText(lines.join('\n'));
};

D.pasteMoves = function() {
  if (!_clip) return;
  const text = _clip.readText();
  const tokens = [...text.matchAll(/[A-I][1-9][x\-][A-I][1-9]/g)].map(m => m[0]);
  if (!tokens.length) { alert('No moves found in clipboard.'); return; }
  D.startGame();
  for (const tok of tokens) {
    const fc = COLS.indexOf(tok[0]), fr = parseInt(tok[1]) - 1;
    const tc = COLS.indexOf(tok[3]), tr = parseInt(tok[4]) - 1;
    const legal = D.legalMoves(D.board);
    const match = legal.find(([f, t]) => f[0]===fc && f[1]===fr && t[0]===tc && t[1]===tr);
    if (!match) { alert(`Illegal move: ${tok}`); return; }
    executeMove(match);
  }
};

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
  for (const tok of tokens) {
    const fc = COLS.indexOf(tok[0]), fr = parseInt(tok[1]) - 1;
    const tc = COLS.indexOf(tok[3]), tr = parseInt(tok[4]) - 1;
    const legal = D.legalMoves(D.board);
    const match = legal.find(([f, t]) => f[0]===fc && f[1]===fr && t[0]===tc && t[1]===tr);
    if (!match) { alert(`Illegal move in file: ${tok}`); return; }
    executeMove(match);
  }
};

D.executeMove     = executeMove;
D.checkPendingWin = checkPendingWin;
D.endGame         = endGame;

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {};
}
})();
