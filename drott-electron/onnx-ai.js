// onnx-ai.js — Astrid: MCTS over an ONNX policy/value net (port of NeuralEngine.swift)
// Uses onnxruntime-node in Electron (nodeIntegration: true).
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

const ort  = typeof require !== 'undefined' ? require('onnxruntime-node') : null;
const path = typeof require !== 'undefined' ? require('path') : null;
const base = typeof __dirname !== 'undefined' ? __dirname : '.';

const NUM_PLANES  = 18;     // 9 piece types × 2 sides
const ACTION_SIZE = 6561;   // 81 from-squares × 81 to-squares
const CPUCT       = 1.0;
const MAX_DEPTH   = 120;    // per-descent cycle cap (same as NeuralEngine.swift)

// Must match drott-rules.js TYPE_CODE exactly (drives FNV hash + plane encoding).
const TYPE_CODE = {
  king:1, berserker:2, spearman:3, bowman:4, elf:5,
  wolf:6, dwarf:7, hunter:8, skjolding:9,
};

// --- Model cache ---
const _sessions = {};

async function _getSession(modelName) {
  if (_sessions[modelName]) return _sessions[modelName];
  if (!ort) throw new Error('onnxruntime-node not available');
  const fs = require('fs');
  const modelPath = path.join(base, 'onnx_models', `${modelName}.onnx`);
  // Read via Node.js fs so Electron's ASAR shim can locate the file inside the
  // archive; then pass the buffer so onnxruntime's native C++ never touches the
  // path itself (it can't read ASAR paths directly).
  const modelBuffer = fs.readFileSync(modelPath);
  const sess = await ort.InferenceSession.create(modelBuffer);
  _sessions[modelName] = sess;
  return sess;
}

// --- Encoding (mirrors drott_game.py / drott_nnet.py / NeuralEngine.swift) ---

// Flat from×to action index (both squares = col + row * 9).
function realAction(from, to) {
  return (from[0] + from[1] * 9) * 81 + (to[0] + to[1] * 9);
}

// Policy is in the mover's canonical frame. For Black, rotate 180° (sq → 80 - sq).
function canonicalAction(realIdx, side) {
  if (side === 'red') return realIdx;
  const f = Math.floor(realIdx / 81), t = realIdx % 81;
  return (80 - f) * 81 + (80 - t);
}

// Build 18×9×9 input planes from the mover's POV. Mirrors fillPlanes() in Swift.
function fillPlanes(board, side) {
  const buf = new Float32Array(NUM_PLANES * 81);
  for (const sq of board.squares) {
    if (!sq) continue;
    const plane = (sq.side === side ? 0 : 9) + TYPE_CODE[sq.type] - 1;
    const r = side === 'red' ? sq.row : 8 - sq.row;
    const c = side === 'red' ? sq.col : 8 - sq.col;
    buf[(plane * 9 + r) * 9 + c] = 1;
  }
  return buf;
}

// Run the net; returns {policy: number[], value: number} or null on error.
async function predict(board, session) {
  const side = board.sideToMove;
  const planes = fillPlanes(board, side);
  const tensor = new ort.Tensor('float32', planes, [1, 18, 9, 9]);
  let results;
  try {
    results = await session.run({ planes: tensor });
  } catch (_) {
    return null;
  }
  return {
    policy: Array.from(results.policy.data),
    value:  results.value.data[0],
  };
}

// --- MCTS ---

function makeCtx(session) {
  return {
    session,
    Qsa: new Map(),  // `${s}_${a}` → Q-value
    Nsa: new Map(),  // `${s}_${a}` → visit count
    Ns:  new Map(),  // `${s}` → visit count
    Ps:  new Map(),  // `${s}` → Float32Array priors (aligned with Vs[s])
    Vs:  new Map(),  // `${s}` → legal moves
  };
}

// Returns value for the calling node (negamax convention). Mirrors Context.search in Swift.
async function _search(board, depth, ctx) {
  if (depth >= MAX_DEPTH) return 0;

  if (board.winner !== null) {
    // winner is the side that just moved; sideToMove is already flipped to the OTHER side.
    const vSelf = (board.winner === board.sideToMove) ? 1 : -1;
    return -vSelf;
  }

  const s = D.repetitionKey(board).toString();

  if (!ctx.Ps.has(s)) {
    // Leaf: expand with network prior.
    const valids = D.legalMoves(board);
    if (valids.length === 0) return 1;   // stuck side loses → parent gets +1
    const pred = await predict(board, ctx.session);
    if (!pred) return 0;
    const side = board.sideToMove;
    const priors = new Float32Array(valids.length);
    let sum = 0;
    for (let i = 0; i < valids.length; i++) {
      const p = pred.policy[canonicalAction(realAction(valids[i][0], valids[i][1]), side)];
      priors[i] = p; sum += p;
    }
    if (sum > 0) { for (let i = 0; i < priors.length; i++) priors[i] /= sum; }
    else         { const u = 1 / valids.length; for (let i = 0; i < priors.length; i++) priors[i] = u; }
    ctx.Ps.set(s, priors);
    ctx.Vs.set(s, valids);
    ctx.Ns.set(s, 0);
    return -pred.value;
  }

  // Internal node: pick max-PUCT move.
  const valids = ctx.Vs.get(s);
  const priors = ctx.Ps.get(s);
  const nS     = ctx.Ns.get(s) || 0;
  const sqrtNS = Math.sqrt(nS);

  let bestU = -Infinity, bestI = 0;
  for (let i = 0; i < valids.length; i++) {
    const a    = realAction(valids[i][0], valids[i][1]);
    const eKey = `${s}_${a}`;
    const nsa  = ctx.Nsa.get(eKey) || 0;
    let u;
    if (ctx.Qsa.has(eKey)) {
      u = ctx.Qsa.get(eKey) + CPUCT * priors[i] * sqrtNS / (1 + nsa);
    } else {
      u = CPUCT * priors[i] * Math.sqrt(nS + 1e-8);
    }
    if (u > bestU) { bestU = u; bestI = i; }
  }

  const mv   = valids[bestI];
  const a    = realAction(mv[0], mv[1]);
  const eKey = `${s}_${a}`;
  const v    = await _search(D.applyMove(board, mv), depth + 1, ctx);

  const nsa = ctx.Nsa.get(eKey) || 0;
  const q   = ctx.Qsa.get(eKey) ?? 0;
  ctx.Qsa.set(eKey, (nsa * q + v) / (nsa + 1));
  ctx.Nsa.set(eKey, nsa + 1);
  ctx.Ns.set(s, nS + 1);
  return -v;
}

// --- Public API ---

// Run MCTS and return the most-visited root move. Mirrors NeuralEngine.bestMove().
async function bestMove(board, modelName, iterations) {
  if (board.winner !== null) return null;
  const legal = D.legalMoves(board);
  if (!legal.length) return null;

  let session;
  try { session = await _getSession(modelName || 'astrid_v0'); }
  catch (_) { return null; }

  const ctx = makeCtx(session);
  const n   = Math.max(1, iterations || 100);
  for (let i = 0; i < n; i++) await _search(board, 0, ctx);

  const rootKey = D.repetitionKey(board).toString();
  let best = legal[0], bestVisits = -1;
  for (const mv of legal) {
    const visits = ctx.Nsa.get(`${rootKey}_${realAction(mv[0], mv[1])}`) || 0;
    if (visits > bestVisits) { bestVisits = visits; best = mv; }
  }
  return best;
}

D.astridMove = bestMove;

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { bestMove, fillPlanes, realAction, canonicalAction };
}
})();
