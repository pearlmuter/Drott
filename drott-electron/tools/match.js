// tools/match.js — headless engine-vs-engine match runner for Drott classical engines.
//
// Plays two engines (by their D.* namespace) head-to-head over many games,
// alternating colors and diversifying openings with a seeded RNG so results are
// reproducible. Engines play their deterministic best move (no endpoint variety),
// so the only difference measured is engine strength.
//
// Usage:
//   node tools/match.js [engineA] [engineB] [--games N] [--depth D | --time T] [--seed S] [--open K] [--maxplies M] [-v]
// Defaults: HR vs HB, 60 games, depth 6, seed 1, 3 opening plies, 240-ply cap.
//
// Examples:
//   node tools/match.js HR HB --games 100 --depth 6
//   node tools/match.js HR HB --games 40 --time 1.0

const DIR = require('path').join(__dirname, '..');
globalThis.D = {};
require(DIR + '/board-state.js');
require(DIR + '/drott-rules.js');
require(DIR + '/herringbone-ai.js');
try { require(DIR + '/halibut-ai.js'); } catch (_) { /* may not exist yet */ }
const D = globalThis.D;

// ---- args ------------------------------------------------------------------
const argv = process.argv.slice(2);
function flag(name, def) {
  const i = argv.indexOf(name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
}
const hasFlag = (n) => argv.indexOf(n) >= 0;
const positional = argv.filter((a, i) =>
  !a.startsWith('--') && !(i > 0 && argv[i - 1].startsWith('--')));
const NAME_A = positional[0] || 'HR';
const NAME_B = positional[1] || 'HB';
const GAMES   = parseInt(flag('--games', '60'), 10);
const DEPTH   = flag('--depth', null) !== null ? parseInt(flag('--depth', '6'), 10) : null;
const TIME    = flag('--time', null)  !== null ? parseFloat(flag('--time', '1')) : null;
const SEED0   = parseInt(flag('--seed', '1'), 10);
const OPEN_PLIES = parseInt(flag('--open', '3'), 10);
const MAX_PLIES  = parseInt(flag('--maxplies', '240'), 10);
const VERBOSE = hasFlag('-v') || hasFlag('--verbose');
const USE_DEPTH = TIME === null;   // depth mode unless --time given

// ---- seeded RNG (mulberry32) ----------------------------------------------
function makeRng(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ---- engine adapter --------------------------------------------------------
// Returns a function (board, history) -> best move, deterministic.
function engineMover(name) {
  const eng = D[name];
  if (!eng || typeof eng.search !== 'function') {
    throw new Error(`Engine '${name}' not found (needs D.${name}.search). ` +
      `Available: ${Object.keys(D).filter(k => D[k] && D[k].search).join(', ') || 'none'}`);
  }
  return function (board, history) {
    const r = USE_DEPTH ? eng.search(board, history, 999, DEPTH)
                        : eng.search(board, history, TIME);
    return r.best;   // deterministic — no pickMove variety
  };
}

// ---- game playout ----------------------------------------------------------
// redName / blackName pick which engine plays which color.
// openMoves: forced opening plies (applied first, from both engines' view).
function playGame(redName, blackName, openMoves) {
  const movers = { red: engineMover(redName), black: engineMover(blackName) };
  let board = D.makeStartBoard();
  const history = [board];

  // Apply the shared opening line (random but legal).
  for (const mv of openMoves) {
    board = D.applyMove(board, mv);
    history.push(board);
    if (board.winner) break;
  }

  let plies = openMoves.length;
  const seen = new Map();
  for (const b of history) {
    const k = D.repetitionKey(b).toString();
    seen.set(k, (seen.get(k) || 0) + 1);
  }

  while (!board.winner && plies < MAX_PLIES) {
    const side = board.sideToMove;
    const legal = D.legalMoves(board);
    if (!legal.length) { // no moves = loss for side to move
      return { winner: D.otherSide(side), reason: 'stalemate', plies };
    }
    const mv = movers[side](board, history);
    if (!mv) return { winner: D.otherSide(side), reason: 'nomove', plies };
    board = D.applyMove(board, mv);
    history.push(board);
    plies++;

    const k = D.repetitionKey(board).toString();
    const n = (seen.get(k) || 0) + 1;
    seen.set(k, n);
    if (n >= 3) return { winner: null, reason: 'repetition', plies };
  }

  if (board.winner) return { winner: board.winner, reason: board.winReason, plies };
  return { winner: null, reason: 'plycap', plies };
}

// ---- random opening line ---------------------------------------------------
function randomOpening(rng, k) {
  let board = D.makeStartBoard();
  const moves = [];
  for (let i = 0; i < k; i++) {
    const legal = D.legalMoves(board);
    if (!legal.length) break;
    const mv = legal[Math.floor(rng() * legal.length)];
    moves.push(mv);
    board = D.applyMove(board, mv);
    if (board.winner) break;
  }
  return moves;
}

// ---- run the match ---------------------------------------------------------
console.log(`Match: ${NAME_A} vs ${NAME_B}  |  ${GAMES} games  |  ` +
  `${USE_DEPTH ? `depth ${DEPTH}` : `${TIME}s/move`}  |  seed ${SEED0}  |  ${OPEN_PLIES} opening plies`);

let aWins = 0, bWins = 0, draws = 0;
const reasons = {};
const t0 = Date.now();

// Each opening is played twice (colors swapped) for fairness -> pairs of games.
const pairs = Math.ceil(GAMES / 2);
let gameNo = 0;
for (let p = 0; p < pairs; p++) {
  const rng = makeRng(SEED0 + p * 7919);
  const opening = randomOpening(rng, OPEN_PLIES);

  // Game 1: A=red, B=black
  for (const [redName, blackName, aIsRed] of [[NAME_A, NAME_B, true], [NAME_B, NAME_A, false]]) {
    if (gameNo >= GAMES) break;
    gameNo++;
    const res = playGame(redName, blackName, opening);
    reasons[res.reason] = (reasons[res.reason] || 0) + 1;
    let tag;
    if (res.winner === null) { draws++; tag = 'draw'; }
    else {
      const aWon = (res.winner === 'red') === aIsRed;
      if (aWon) { aWins++; tag = `${NAME_A} wins`; }
      else      { bWins++; tag = `${NAME_B} wins`; }
    }
    if (VERBOSE) {
      console.log(`  game ${gameNo}: ${aIsRed ? NAME_A + '=red' : NAME_B + '=red'} -> ` +
        `${tag} (${res.reason}, ${res.plies} plies)`);
    }
  }
}

const dt = (Date.now() - t0) / 1000;
const decisive = aWins + bWins;
const total = aWins + bWins + draws;
const scoreA = (aWins + draws / 2);
const pct = total ? (100 * scoreA / total) : 0;

// Elo estimate from score fraction (guard against 0/1).
function elo(scoreFrac) {
  const s = Math.min(0.999, Math.max(0.001, scoreFrac));
  return -400 * Math.log10(1 / s - 1);
}
const eloDiff = elo(scoreA / total);

console.log('');
console.log(`Results (${total} games, ${dt.toFixed(1)}s):`);
console.log(`  ${NAME_A}: ${aWins} wins   ${NAME_B}: ${bWins} wins   draws: ${draws}`);
console.log(`  ${NAME_A} score: ${scoreA}/${total} = ${pct.toFixed(1)}%   ` +
  `(Elo diff ${NAME_A}−${NAME_B} ≈ ${eloDiff >= 0 ? '+' : ''}${eloDiff.toFixed(0)})`);
console.log(`  decisive: ${decisive}/${total}   reasons: ${JSON.stringify(reasons)}`);
