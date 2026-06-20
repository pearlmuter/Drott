// herringbone-worker.js — runs HR search off the main thread via worker_threads
const { parentPort } = require('worker_threads');
const path = require('path');

globalThis.D = {};
require(path.join(__dirname, 'drott-rules.js'));
require(path.join(__dirname, 'herringbone-ai.js'));

parentPort.on('message', ({ board, thinkTime }) => {
  try {
    const result = D.HR.search(board, [], thinkTime);
    const move   = D.HR.pickMove(result, board);
    parentPort.postMessage({ move, score: result.score, depth: result.depth });
  } catch (e) {
    parentPort.postMessage({ error: String(e) });
  }
});
