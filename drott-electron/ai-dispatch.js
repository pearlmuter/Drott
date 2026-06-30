// ai-dispatch.js — routes to the correct AI engine and triggers AI turns
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

D.isAILocked = false;

// Generation counter — incremented on abort/new-game so stale IPC results are ignored.
let _gen = 0;

D.terminateHRWorker = function() {
  _gen++;
  const { ipcRenderer } = require('electron');
  try { ipcRenderer.invoke('hr-abort'); } catch (_) {}
  try { ipcRenderer.invoke('astrid-abort'); } catch (_) {}
};

function hrSearch(board, thinkTime) {
  const { ipcRenderer } = require('electron');
  return ipcRenderer.invoke('hr-search', {
    board: JSON.parse(JSON.stringify(board)),
    thinkTime,
  });
}

function astridSearch(board, modelName, iterations) {
  const { ipcRenderer } = require('electron');
  return ipcRenderer.invoke('astrid-search', {
    board: JSON.parse(JSON.stringify(board)),
    modelName: modelName || 'astrid_v2',
    iterations: iterations || 100,
  });
}

D.triggerAIIfNeeded = function() {
  if (!D.board || D.board.winner || D.gamePhase !== 'playing') return;
  if (D.checkPendingWin && D.checkPendingWin()) return;
  if (D.isAILocked) return;

  const side  = D.board.sideToMove;
  const setup = side === 'red' ? D.redSetup : D.blackSetup;
  if (setup.kind === 'human') return;

  D.isAILocked = true;
  if (D.setThinking) D.setThinking(true);
  setTimeout(() => runAITurn(side, setup), 50);
};

async function runAITurn(side, setup) {
  const myGen = _gen;
  try {
    let move = null;
    if (setup.kind === 'herringbone') {
      const result = await hrSearch(D.board, setup.thinkTime || 5);
      if (_gen !== myGen) return;
      if (result && result.move) {
        if (D.showEval) D.showEval(result.score, result.depth, side);
        move = result.move;
      } else if (result && result.error) {
        console.error('HR search error:', result.error);
      }
    } else if (setup.kind === 'astrid') {
      const result = await astridSearch(D.board, setup.model, setup.iterations);
      if (_gen !== myGen) return;
      if (result && result.move) {
        move = result.move;
      } else if (result && result.error) {
        console.error('Astrid search error:', result.error);
      }
    }
    if (move && D.gamePhase === 'playing' && D.board.sideToMove === side) {
      D.executeMove(move);
    }
  } catch (err) {
    console.error('runAITurn error:', err);
  } finally {
    // Only touch shared state when this search is still the current one.
    // Stale searches (aborted / new game started) must not unlock or re-trigger.
    const isCurrent = (_gen === myGen);
    if (isCurrent) {
      D.isAILocked = false;
      if (D.setThinking) D.setThinking(false);
      if (D.gamePhase === 'playing') D.triggerAIIfNeeded();
    }
  }
}

function randomMove(board) {
  const moves = D.legalMoves(board);
  if (!moves.length) return null;
  return moves[Math.floor(Math.random() * moves.length)];
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {};
}
})();
