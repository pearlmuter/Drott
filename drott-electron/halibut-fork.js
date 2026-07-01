// Spawned by main.js via child_process.fork with ELECTRON_RUN_AS_NODE=1.
// Runs the Halibut search in a separate process (renderer never blocks).
//
// Difficulty is expressed as three knobs, all applied here — the search itself
// stays deterministic; stochasticity lives only in pickMove (the endpoint):
//   thinkTime : seconds budget for iterative deepening
//   depthCap  : hard ply cap (weaker levels search shallower)
//   variety   : centipawn margin for the endpoint move pool (0 = always best)
const path = require('path');

globalThis.D = {};
require(path.join(__dirname, 'drott-rules.js'));
require(path.join(__dirname, 'halibut-ai.js'));
const _D = globalThis.D;

process.on('message', ({ board, thinkTime, depthCap, variety }) => {
  try {
    const result = _D.HB.search(board, [], thinkTime, depthCap);
    const move   = _D.HB.pickMove(result, board, variety);
    process.send({ move, score: result.score, depth: result.depth });
  } catch (e) {
    process.send({ error: String(e) });
  }
});
