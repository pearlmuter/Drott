// Spawned by main.js via child_process.fork with ELECTRON_RUN_AS_NODE=1
// Runs the Herringbone search in a completely separate process (no blocking).
const path = require('path');

globalThis.D = {};
require(path.join(__dirname, 'drott-rules.js'));
require(path.join(__dirname, 'herringbone-ai.js'));
const _D = globalThis.D;

process.on('message', ({ board, thinkTime }) => {
  try {
    const result = _D.HR.search(board, [], thinkTime);
    const move   = _D.HR.pickMove(result, board);
    process.send({ move, score: result.score, depth: result.depth });
  } catch (e) {
    process.send({ error: String(e) });
  }
});
