// herringbone-ai.js — Herringbone (HR) classical engine, port of Engine.swift
// Full negamax kernel: TT + PVS + aspiration windows + LMR + SEE + quiescence.
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

const _N  = 9;
const _SQ = _N * _N; // 81

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const MATE          = 1_000_000;
const INFINITY_     = 2_000_000;
const MAX_DEPTH     = 32;
const VARIETY_MARGIN     = 30;
const ASPIRATION_WINDOW  = 50;
const MATE_THRESHOLD     = MATE - MAX_DEPTH - 1;

function isMateScore(s) { return Math.abs(s) > MATE_THRESHOLD; }

// ---------------------------------------------------------------------------
// Piece values
// ---------------------------------------------------------------------------
const BASE_VALUE = {
  king: 0, skjolding: 100,
  spearman: 200, bowman: 200, berserker: 200,
  wolf: 300, hunter: 300,
  dwarf: 500, elf: 500,
};
const SEE_VALUE = { ...BASE_VALUE, king: 10_000 };

function baseValue(type) { return BASE_VALUE[type] || 0; }
function seeValue(type)  { return SEE_VALUE[type]  || 0; }

// Positional weights
const PAWN_CENTER_W = 6;
const MINOR_FILE_W  = 6;
const FLANK_FILE_W  = 4;
const DEVELOP_W     = 4;

function chebyshev(c1, r1, c2, r2) { return Math.max(Math.abs(c1-c2), Math.abs(r1-r2)); }

function flankDevelopment(p, centerCol) {
  const flank   = Math.abs(p.col - centerCol);
  const advance = p.side === 'red' ? p.row : (_N - 1 - p.row);
  return flank * FLANK_FILE_W + Math.min(advance, 3) * DEVELOP_W;
}

// ---------------------------------------------------------------------------
// Move helpers (move = [[fc,fr],[tc,tr],isCapture])
// ---------------------------------------------------------------------------
function moveEq(a, b) {
  return a && b &&
    a[0][0] === b[0][0] && a[0][1] === b[0][1] &&
    a[1][0] === b[1][0] && a[1][1] === b[1][1];
}

function captureMovesFor(board, side) {
  return D.legalMoves({ ...board, sideToMove: side }).filter(m => m[2]);
}

// ---------------------------------------------------------------------------
// Repetition tracker
// ---------------------------------------------------------------------------
class Repetition {
  constructor(boards) {
    this.counts = new Map();
    for (const b of boards) {
      const k = D.repetitionKey(b).toString();
      this.counts.set(k, (this.counts.get(k) || 0) + 1);
    }
  }
  enter(key) {
    const k = key.toString();
    const n = (this.counts.get(k) || 0) + 1;
    this.counts.set(k, n);
    return n;
  }
  leave(key) {
    const k = key.toString();
    const n = this.counts.get(k) || 0;
    if (n > 1) this.counts.set(k, n - 1); else this.counts.delete(k);
  }
}

// ---------------------------------------------------------------------------
// Search context (TT, killers, history, deadline)
// ---------------------------------------------------------------------------
class SearchContext {
  constructor(deadline, rep) {
    this.deadline     = deadline;   // ms timestamp (Date.now() + timeLimit*1000)
    this.rep          = rep;
    this.tt           = new Map();
    this.killers      = new Array((MAX_DEPTH + 2) * 2).fill(null);
    this.history      = new Int32Array(_SQ * _SQ);
    this._deadCheck   = 0;
    this._expired     = false;
  }

  get isExpired() { return this._expired; }

  timedOut() {
    if (this._expired) return true;
    this._deadCheck = (this._deadCheck + 1) & 0x3F;
    if (this._deadCheck === 0 && Date.now() >= this.deadline) this._expired = true;
    return this._expired;
  }

  killer(ply, slot) {
    const i = ply * 2 + slot;
    return i < this.killers.length ? this.killers[i] : null;
  }

  _histIdx(m) {
    return (m[0][0] + m[0][1] * _N) * _SQ + (m[1][0] + m[1][1] * _N);
  }

  historyScore(m) { return this.history[this._histIdx(m)]; }

  recordCutoff(m, ply, depth) {
    if (m[2]) return;   // captures only
    const base = ply * 2;
    if (base + 1 < this.killers.length && !moveEq(this.killers[base], m)) {
      this.killers[base + 1] = this.killers[base];
      this.killers[base]     = m;
    }
    this.history[this._histIdx(m)] += depth * depth;
  }
}

// ---------------------------------------------------------------------------
// Static Exchange Evaluation (SEE)
// ---------------------------------------------------------------------------
function cheapestAttacker(board, toCol, toRow, side) {
  const caps = D.legalMoves({ ...board, sideToMove: side })
    .filter(m => m[2] && m[1][0] === toCol && m[1][1] === toRow);
  if (!caps.length) return null;
  let best = null, bestVal = Infinity;
  for (const m of caps) {
    const p = board.squares[m[0][0] + m[0][1] * _N];
    if (p) {
      const v = seeValue(p.type);
      if (v < bestVal) { bestVal = v; best = m[0]; }
    }
  }
  return best;
}

function staticExchangeEval(board, mv) {
  const victim   = board.squares[mv[1][0] + mv[1][1] * _N];
  const attacker = board.squares[mv[0][0] + mv[0][1] * _N];
  if (!victim || !attacker) return 0;

  const gain = [seeValue(victim.type)];
  // Clone squares (shallow array copy — good enough for SEE)
  const b = { ...board, squares: board.squares.slice() };
  const toIdx   = mv[1][0] + mv[1][1] * _N;
  const fromIdx = mv[0][0] + mv[0][1] * _N;
  b.squares[toIdx]   = { type: attacker.type, side: attacker.side, col: mv[1][0], row: mv[1][1] };
  b.squares[fromIdx] = null;

  let onSquare = seeValue(attacker.type);
  let side     = attacker.side === 'red' ? 'black' : 'red';
  let d = 0;

  while (true) {
    const from = cheapestAttacker(b, mv[1][0], mv[1][1], side);
    if (!from) break;
    d++;
    gain.push(onSquare - gain[d - 1]);
    if (Math.max(-gain[d - 1], gain[d]) < 0) break;
    const p = b.squares[from[0] + from[1] * _N];
    b.squares[toIdx]              = { type: p.type, side: p.side, col: mv[1][0], row: mv[1][1] };
    b.squares[from[0] + from[1] * _N] = null;
    onSquare = seeValue(p.type);
    side = side === 'red' ? 'black' : 'red';
  }

  while (d > 0) {
    gain[d - 1] = -Math.max(-gain[d - 1], gain[d]);
    d--;
  }
  return gain[0];
}

// ---------------------------------------------------------------------------
// Move ordering
// ---------------------------------------------------------------------------
function orderKey(mv, board, ctx, ttMove, k0, k1) {
  if (moveEq(ttMove, mv)) return 1_000_000_000;
  if (mv[2]) {
    const victim   = board.squares[mv[1][0] + mv[1][1] * _N];
    if (!victim) return 0;
    if (victim.type === 'king') return 900_000_000;
    const attType  = (board.squares[mv[0][0] + mv[0][1] * _N] || {}).type || 'skjolding';
    const mvvlva   = baseValue(victim.type) * 16 - baseValue(attType);
    if (baseValue(victim.type) < baseValue(attType)) {
      const see = staticExchangeEval(board, mv);
      if (see < 0) return -100_000 + see;
    }
    return 500_000_000 + mvvlva;
  }
  if (moveEq(k0, mv)) return 400_000_000;
  if (moveEq(k1, mv)) return 399_000_000;
  return ctx.historyScore(mv);
}

function orderMoves(moves, board, ctx, ply, ttMove) {
  const k0 = ctx.killer(ply, 0);
  const k1 = ctx.killer(ply, 1);
  const keyed = moves.map(mv => ({ mv, key: orderKey(mv, board, ctx, ttMove, k0, k1) }));
  keyed.sort((a, b) => b.key - a.key);
  return keyed.map(x => x.mv);
}

// ---------------------------------------------------------------------------
// Static evaluation
// ---------------------------------------------------------------------------
function evaluate(board, me) {
  const opp     = me === 'red' ? 'black' : 'red';
  const [cx, cy] = D.CASTLE;   // [4,4]
  const centerCol = Math.floor(_N / 2);
  const half      = Math.floor(_N / 2);
  let score = 0;
  let myKingC = -1, myKingR = -1, oppKingC = -1, oppKingR = -1;
  let myFortDef = 0, oppFortDef = 0, myInOpp = 0, oppInMy = 0;
  let myMidDev = 0, oppMidDev = 0, myMajDev = 0, oppMajDev = 0;

  for (const p of board.squares) {
    if (!p) continue;
    const sgn = p.side === me ? 1 : -1;
    score += sgn * baseValue(p.type);

    switch (p.type) {
      case 'king':
        if (p.side === me) { myKingC = p.col; myKingR = p.row; }
        else               { oppKingC = p.col; oppKingR = p.row; }
        break;
      case 'skjolding': {
        const closeness = half - chebyshev(p.col, p.row, cx, cy);
        if (closeness > 0) score += sgn * closeness * PAWN_CENTER_W;
        const adv = p.side === 'red' ? p.row : (_N - 1 - p.row);
        score += sgn * adv * 4;
        break;
      }
      case 'spearman': case 'bowman': case 'berserker': {
        const centralFile = half - Math.abs(p.col - centerCol);
        if (centralFile > 0) score += sgn * centralFile * MINOR_FILE_W;
        break;
      }
      case 'wolf': case 'hunter': {
        const d = flankDevelopment(p, centerCol);
        score += sgn * d;
        if (p.side === me) myMidDev += d; else oppMidDev += d;
        break;
      }
      case 'dwarf': case 'elf': {
        const d = flankDevelopment(p, centerCol);
        score += sgn * d;
        if (p.side === me) myMajDev += d; else oppMajDev += d;
        break;
      }
    }

    if (D.isFort(p.col, p.row, p.side)) {
      if (p.side === me) myFortDef++; else oppFortDef++;
    }
    if (p.side === me  && D.isFort(p.col, p.row, opp)) myInOpp++;
    if (p.side === opp && D.isFort(p.col, p.row, me))  oppInMy++;
  }

  // Develop middle before major
  score -= Math.max(0, myMajDev  - myMidDev);
  score += Math.max(0, oppMajDev - oppMidDev);

  // Win condition 2: king toward / on the castle
  if (myKingC >= 0) {
    score += (myKingC === cx && myKingR === cy)
      ? 5000 : (5 - chebyshev(myKingC, myKingR, cx, cy)) * 6;
  }
  if (oppKingC >= 0) {
    score -= (oppKingC === cx && oppKingR === cy)
      ? 5000 : (5 - chebyshev(oppKingC, oppKingR, cx, cy)) * 6;
  }

  // Win condition 3: fort attack and defense
  score += myInOpp  * 200;
  score -= oppInMy  * 200;
  if (myInOpp  > 0 && oppFortDef === 0) score += 6000;
  if (oppInMy  > 0 && myFortDef  === 0) score -= 6000;
  score += myFortDef  > 0 ? 120 : 0;
  score -= oppFortDef > 0 ? 120 : 0;

  return score;
}

// ---------------------------------------------------------------------------
// Quiescence search
// ---------------------------------------------------------------------------
function quiesce(board, alpha, beta, ply, ctx) {
  if (board.winner) {
    const s = MATE - ply;
    return board.winner === board.sideToMove ? s : -s;
  }

  const standPat = evaluate(board, board.sideToMove);
  if (standPat >= beta) return beta;
  alpha = Math.max(alpha, standPat);
  if (ply >= MAX_DEPTH) return alpha;

  const caps = orderMoves(
    D.legalMoves(board).filter(m => m[2]),
    board, ctx, ply, null
  );

  for (const mv of caps) {
    if (ctx.timedOut()) break;
    const victim = board.squares[mv[1][0] + mv[1][1] * _N];
    if (victim && victim.type !== 'king' &&
        !D.isFort(mv[1][0], mv[1][1], victim.side) &&
        staticExchangeEval(board, mv) < 0) continue;
    const child = D.applyMove(board, mv);
    const score = -quiesce(child, -beta, -alpha, ply + 1, ctx);
    if (score >= beta) return beta;
    if (score > alpha) alpha = score;
  }
  return alpha;
}

// ---------------------------------------------------------------------------
// Negamax + alpha-beta + TT + PVS + LMR
// ---------------------------------------------------------------------------
function negamax(board, key, depth, alpha, beta, ply, ctx) {
  if (board.winner) {
    const s = MATE - ply;
    return board.winner === board.sideToMove ? s : -s;
  }

  const alphaOrig = alpha;
  let ttMove = null;
  const ttKey = key.toString();
  const tte = ctx.tt.get(ttKey);
  if (tte) {
    ttMove = tte.bestMove;
    if (tte.depth >= depth) {
      if      (tte.flag === 'exact') return tte.score;
      else if (tte.flag === 'lower') alpha = Math.max(alpha, tte.score);
      else if (tte.flag === 'upper') beta  = Math.min(beta,  tte.score);
      if (alpha >= beta) return tte.score;
    }
  }

  if (depth <= 0) return quiesce(board, alpha, beta, ply, ctx);

  const moves = orderMoves(D.legalMoves(board), board, ctx, ply, ttMove);
  if (!moves.length) return -(MATE - ply);

  const k0 = ctx.killer(ply, 0), k1 = ctx.killer(ply, 1);
  let best = -INFINITY_, bestMove = null, searchedFirst = false, moveIndex = 0;

  for (const mv of moves) {
    if (ctx.timedOut()) break;
    const child    = D.applyMove(board, mv);
    const childKey = D.repetitionKey(child);
    const reps     = ctx.rep.enter(childKey);
    let score;

    if (reps >= 3) {
      score = 0;
    } else if (!searchedFirst) {
      score = -negamax(child, childKey, depth - 1, -beta, -alpha, ply + 1, ctx);
    } else {
      const quiet     = !mv[2] && !moveEq(mv, k0) && !moveEq(mv, k1);
      const reduction = (depth >= 3 && moveIndex >= 3 && quiet) ? 1 : 0;
      score = -negamax(child, childKey, depth - 1 - reduction, -alpha - 1, -alpha, ply + 1, ctx);
      if (reduction > 0 && score > alpha) {
        score = -negamax(child, childKey, depth - 1, -alpha - 1, -alpha, ply + 1, ctx);
      }
      if (score > alpha && score < beta) {
        score = -negamax(child, childKey, depth - 1, -beta, -alpha, ply + 1, ctx);
      }
    }

    ctx.rep.leave(childKey);
    searchedFirst = true;
    moveIndex++;

    if (score > best) { best = score; bestMove = mv; }
    if (best > alpha) alpha = best;
    if (alpha >= beta) {
      ctx.recordCutoff(mv, ply, depth);
      break;
    }
  }

  if (!ctx.timedOut() && !isMateScore(best)) {
    const flag = best <= alphaOrig ? 'upper' : (best >= beta ? 'lower' : 'exact');
    ctx.tt.set(ttKey, { depth, score: best, flag, bestMove });
  }
  return best;
}

// ---------------------------------------------------------------------------
// Root search (multi-line PVS with aspiration)
// ---------------------------------------------------------------------------
function searchRoot(board, depth, ordering, ctx, alpha0, beta) {
  let alpha = alpha0;
  const scored = [];
  let best = ordering[0], bestScore = -INFINITY_, completed = true;

  for (let i = 0; i < ordering.length; i++) {
    if (ctx.timedOut()) { completed = false; break; }
    const mv    = ordering[i];
    const child = D.applyMove(board, mv);
    const key   = D.repetitionKey(child);
    const reps  = ctx.rep.enter(key);
    let score;

    if (reps >= 3) {
      score = 0;
    } else if (i === 0) {
      score = -negamax(child, key, depth - 1, -beta, -alpha, 1, ctx);
    } else {
      score = -negamax(child, key, depth - 1, -alpha - 1, -alpha, 1, ctx);
      if (score > alpha && score < beta) {
        score = -negamax(child, key, depth - 1, -beta, -alpha, 1, ctx);
      }
    }
    ctx.rep.leave(key);
    scored.push({ mv, score });
    if (score > bestScore) { bestScore = score; best = mv; }
    if (score > alpha) alpha = score;
  }

  if (ctx.isExpired) completed = false;

  if (!completed) {
    return { best, bestScore, second: null, secondScore: -INFINITY_,
             ordering, scored: [], completed: false };
  }

  scored.sort((a, b) => b.score - a.score);
  return {
    best: scored[0].mv, bestScore: scored[0].score,
    second: scored.length > 1 ? scored[1].mv : null,
    secondScore: scored.length > 1 ? scored[1].score : -INFINITY_,
    ordering: scored.map(x => x.mv), scored, completed: true,
  };
}

// ---------------------------------------------------------------------------
// Public: search
// ---------------------------------------------------------------------------
function search(board, history, timeLimit, depthLimit) {
  if (depthLimit === undefined) depthLimit = MAX_DEPTH;
  const ctx = new SearchContext(
    Date.now() + Math.round(timeLimit * 1000),
    new Repetition(history || [])
  );

  let ordering = orderMoves(D.legalMoves(board), board, ctx, 0, null);
  if (!ordering.length) {
    return { best: null, secondBest: null, score: -MATE, secondScore: -MATE,
             depth: 0, rootMoves: [] };
  }

  let result = {
    best: ordering[0], secondBest: ordering.length > 1 ? ordering[1] : null,
    score: -INFINITY_, secondScore: -INFINITY_, depth: 0, rootMoves: [],
  };

  let depth = 1, prevScore = 0;
  while (depth <= Math.min(depthLimit, MAX_DEPTH)) {
    let alpha = -INFINITY_, beta = INFINITY_;
    if (depth >= 4 && !isMateScore(prevScore)) {
      alpha = prevScore - ASPIRATION_WINDOW;
      beta  = prevScore + ASPIRATION_WINDOW;
    }

    let iter = searchRoot(board, depth, ordering, ctx, alpha, beta);
    if (iter.completed && (alpha !== -INFINITY_ || beta !== INFINITY_) &&
        (iter.bestScore <= alpha || iter.bestScore >= beta)) {
      iter = searchRoot(board, depth, ordering, ctx, -INFINITY_, INFINITY_);
    }
    if (!iter.completed) break;

    result.best        = iter.best;
    result.score       = iter.bestScore;
    result.secondBest  = iter.second;
    result.secondScore = iter.secondScore;
    result.rootMoves   = iter.scored;
    result.depth       = depth;
    prevScore          = iter.bestScore;
    ordering           = iter.ordering;
    if (isMateScore(iter.bestScore) && iter.bestScore > 0) break;
    depth++;
  }
  return result;
}

// ---------------------------------------------------------------------------
// Public: bestMove, pickMove, hangsMovedPiece
// ---------------------------------------------------------------------------
function bestMove(board, timeLimit) {
  return search(board, [], timeLimit).best;
}

function hangsMovedPiece(mv, board) {
  const after = D.applyMove(board, mv);
  if (after.winner) return false;
  for (const cap of captureMovesFor(after, after.sideToMove)) {
    if (cap[1][0] === mv[1][0] && cap[1][1] === mv[1][1]) {
      if (staticExchangeEval(after, cap) > 0) return true;
    }
  }
  return false;
}

function pickMove(result, board, allowVariety) {
  if (allowVariety === undefined) allowVariety = true;
  if (!result.best) return null;
  if (!allowVariety || !result.rootMoves.length) return result.best;
  if (result.score >= MATE_THRESHOLD) return result.best;

  const pool = [result.best];
  for (const { mv, score } of result.rootMoves) {
    if (moveEq(mv, result.best)) continue;
    if (result.score - score > VARIETY_MARGIN) break;
    if (score <= -MATE_THRESHOLD) continue;
    if (board && hangsMovedPiece(mv, board)) continue;
    pool.push(mv);
  }
  if (pool.length <= 1) return result.best;
  return pool[Math.floor(Math.random() * pool.length)];
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------
D.HR = {
  search, bestMove, pickMove, evaluate, staticExchangeEval,
  hangsMovedPiece, MATE, MAX_DEPTH, VARIETY_MARGIN, ASPIRATION_WINDOW,
};

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { search, bestMove, pickMove, evaluate, staticExchangeEval };
}
})();
