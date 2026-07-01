// halibut-ai.js — Halibut (HB) classical engine.
// A stronger descendant of Herringbone (herringbone-ai.js). Same deterministic
// negamax kernel + TT + PVS + aspiration + quiescence, plus:
//   - lighter move ordering (MVV-LVA; SEE only in quiescence) for throughput
//   - null-move pruning (zero-window, material-guarded)
//   - depth-scaled late move reductions
//   - king base value + king-safety (tropism) evaluation
//   - optional win-condition search extensions
//
// The search is 100% deterministic. Randomness lives only in pickMove (endpoint),
// scaled by difficulty. Herringbone stays frozen as the A/B baseline.
//
// Feature flags (env HB_* = "0"/"1" in the match harness; default shown):
//   HB_LIGHTORDER=1  HB_NULLMOVE=1  HB_LMR2=1  HB_KINGSAFE=1  HB_EXT=0
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

const _ENV = (typeof process !== 'undefined' && process.env) ? process.env : {};
function feat(name, def) {
  const v = _ENV[name];
  if (v === undefined || v === '') return def;
  return v === '1' || v === 'true';
}
// Defaults reflect measured results (match harness, equal depth vs Herringbone):
//   LIGHTORDER +9/neutral & ~30% faster; LMR2 neutral & faster; KINGSAFE +44 Elo.
//   Combined (below) beats Herringbone by ~+56 Elo at equal depth.
//   NULLMOVE measured −35 Elo (unsound in a king-capture game with no "check")
//   -> OFF by default, kept flag-gated for future work with a verification search.
// Win-condition search extensions were tried and removed: they don't terminate
// cleanly (a king parked near the castle stays "critical", so the extension never
// pays back its depth). King-safety eval covers win-condition awareness instead.
const F = {
  LIGHTORDER: feat('HB_LIGHTORDER', true),
  NULLMOVE:   feat('HB_NULLMOVE',   false),
  LMR2:       feat('HB_LMR2',       true),
  KINGSAFE:   feat('HB_KINGSAFE',   true),
  // Standing-threat eval term: charges the side to move a fraction (HB_THREAT_W,
  // default 0.5) of the biggest piece the opponent can win by SEE, so a soft
  // hanging piece feels urgent. Measured vs Herringbone (depth 4, 40 games):
  // baseline +56 Elo, w=0.5 +44, w=1.0 +70 — all within noise, and ~17% slower
  // eval. No clear strength gain, so OFF by default; kept flag-gated for tuning
  // (it does make the engine more materialistic / "look smarter" about hanging
  // pieces, a perception vs strength trade).
  THREAT:     feat('HB_THREAT',     false),
};

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
// Piece values — king now carries a base value (~one Skjolding) per design note.
// (Both sides always have exactly one king in any non-terminal node, so this
//  cancels in material; it matters for king-in-danger via the safety term.)
// ---------------------------------------------------------------------------
const BASE_VALUE = {
  king: 100, skjolding: 100,
  spearman: 200, bowman: 200, berserker: 200,
  wolf: 300, hunter: 300,
  dwarf: 500, elf: 500,
};
const SEE_VALUE = { ...BASE_VALUE, king: 10_000 };

function baseValue(type) { return BASE_VALUE[type] || 0; }
function seeValue(type)  { return SEE_VALUE[type]  || 0; }

// King-safety tropism weights: how threatening each attacker type is near a king.
const TROPISM_W = {
  king: 0, skjolding: 1,
  spearman: 2, bowman: 2, berserker: 2,
  wolf: 3, hunter: 3,
  dwarf: 4, elf: 4,
};

// Positional weights (PAWN_* env-tunable for center-bias experiments)
const PAWN_CENTER_W = _ENV.HB_PAWN_CENTER_W ? parseFloat(_ENV.HB_PAWN_CENTER_W) : 6;
const PAWN_ADV_W    = _ENV.HB_PAWN_ADV_W    ? parseFloat(_ENV.HB_PAWN_ADV_W)    : 4;
const MINOR_FILE_W  = 6;
const FLANK_FILE_W  = 4;
const DEVELOP_W     = 4;
const KING_SAFETY_W = 4;
const THREAT_W      = _ENV.HB_THREAT_W ? parseFloat(_ENV.HB_THREAT_W) : 0.5;   // fraction of a standing SEE-winning threat charged to the side to move

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
    this.deadline     = deadline;
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
    if (m[2]) return;
    const base = ply * 2;
    if (base + 1 < this.killers.length && !moveEq(this.killers[base], m)) {
      this.killers[base + 1] = this.killers[base];
      this.killers[base]     = m;
    }
    this.history[this._histIdx(m)] += depth * depth;
  }
}

// ---------------------------------------------------------------------------
// Static Exchange Evaluation (SEE) — used only in quiescence now.
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
//   LIGHTORDER: captures ranked by MVV-LVA only (no SEE) -> big throughput win.
//   else: Herringbone's SEE-in-ordering behaviour.
// ---------------------------------------------------------------------------
function orderKey(mv, board, ctx, ttMove, k0, k1) {
  if (moveEq(ttMove, mv)) return 1_000_000_000;
  if (mv[2]) {
    const victim = board.squares[mv[1][0] + mv[1][1] * _N];
    if (!victim) return 0;
    if (victim.type === 'king') return 900_000_000;
    const attType = (board.squares[mv[0][0] + mv[0][1] * _N] || {}).type || 'skjolding';
    const mvvlva  = baseValue(victim.type) * 16 - baseValue(attType);
    if (!F.LIGHTORDER && baseValue(victim.type) < baseValue(attType)) {
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
  const [cx, cy] = D.CASTLE;
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
        score += sgn * adv * PAWN_ADV_W;
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

  // King safety (tropism): enemy pieces crowding a king are dangerous; reward
  // swarming the opponent king, penalise letting attackers near your own.
  if (F.KINGSAFE && myKingC >= 0 && oppKingC >= 0) {
    let dangerToMe = 0, dangerToOpp = 0;
    for (const p of board.squares) {
      if (!p || p.type === 'king') continue;
      const w = TROPISM_W[p.type] || 0;
      if (w === 0) continue;
      if (p.side === opp) {
        const d = chebyshev(p.col, p.row, myKingC, myKingR);
        if (d <= 3) dangerToMe += w * (4 - d);
      } else {
        const d = chebyshev(p.col, p.row, oppKingC, oppKingR);
        if (d <= 3) dangerToOpp += w * (4 - d);
      }
    }
    // Escape squares: fewer empty neighbours around my king = more danger.
    let myEsc = 0;
    for (let dc = -1; dc <= 1; dc++) for (let dr = -1; dr <= 1; dr++) {
      if (!dc && !dr) continue;
      const nc = myKingC + dc, nr = myKingR + dr;
      if (nc < 0 || nc >= _N || nr < 0 || nr >= _N) continue;
      const q = board.squares[nc + nr * _N];
      if (!q || q.side === opp) myEsc++;
    }
    score += (dangerToOpp - dangerToMe) * KING_SAFETY_W;
    score -= Math.max(0, 3 - myEsc) * 6;   // cramped king penalty
  }

  // Standing-threat awareness. Captures are already searched, but a threat the
  // opponent *declines* never enters the score, so a soft (e.g. pawn-value)
  // hanging piece can sit en prise for many moves. Charge the side to move a
  // fraction of the biggest piece the opponent can win by SEE, so it feels the
  // threat and resolves it. Bounded to one opponent move-gen + one SEE per leaf.
  if (F.THREAT) {
    const oppBoard = { squares: board.squares, sideToMove: opp, winner: null };
    let bestCap = null, bestVal = -1;
    for (const cap of D.legalMoves(oppBoard)) {
      if (!cap[2]) continue;
      const victim = board.squares[cap[1][0] + cap[1][1] * _N];
      if (!victim || victim.side !== me || victim.type === 'king') continue;
      const v = baseValue(victim.type);
      if (v > bestVal) { bestVal = v; bestCap = cap; }
    }
    if (bestCap) {
      const see = staticExchangeEval(oppBoard, bestCap);
      if (see > 0) score -= Math.floor(see * THREAT_W);
    }
  }

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
// Helpers for null move / extensions
// ---------------------------------------------------------------------------
function hasNonKingMaterial(board, side) {
  let n = 0;
  for (const p of board.squares) {
    if (p && p.side === side && p.type !== 'king') { n++; if (n >= 2) return true; }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Negamax + alpha-beta + TT + PVS + LMR + null-move
// ---------------------------------------------------------------------------
function negamax(board, key, depth, alpha, beta, ply, ctx) {
  if (board.winner) {
    const s = MATE - ply;
    return board.winner === board.sideToMove ? s : -s;
  }

  const alphaOrig = alpha;
  const isPV = beta - alpha > 1;
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

  // Null-move pruning: on non-PV nodes with material, passing and still failing
  // high means we can prune. Reduced search self-corrects when "in check"
  // (a null move that lets the king be captured returns a mate score, not >=beta).
  if (F.NULLMOVE && !isPV && depth >= 3 && !isMateScore(beta) &&
      hasNonKingMaterial(board, board.sideToMove)) {
    const R = depth >= 6 ? 3 : 2;
    const nullBoard = { squares: board.squares, sideToMove: D.otherSide(board.sideToMove),
                        winner: null, winReason: null };
    const nullKey = D.repetitionKey(nullBoard);
    const score = -negamax(nullBoard, nullKey, depth - 1 - R, -beta, -beta + 1, ply + 1, ctx);
    if (!ctx.isExpired && score >= beta) return isMateScore(score) ? beta : score;
  }

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
      const quiet = !mv[2] && !moveEq(mv, k0) && !moveEq(mv, k1);
      let reduction = 0;
      if (F.LMR2) {
        if (depth >= 3 && moveIndex >= 3 && quiet) {
          reduction = 1;
          if (moveIndex >= 6) reduction++;
          if (depth >= 7)     reduction++;
          if (reduction > depth - 2) reduction = depth - 2;
        }
      } else {
        reduction = (depth >= 3 && moveIndex >= 3 && quiet) ? 1 : 0;
      }
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

// pickMove: endpoint stochasticity only. `variety` controls how many near-best
// moves are eligible; variety=0 -> deterministic best (strongest play).
function pickMove(result, board, variety) {
  if (variety === undefined) variety = VARIETY_MARGIN;
  if (!result.best) return null;
  if (variety <= 0 || !result.rootMoves.length) return result.best;
  if (result.score >= MATE_THRESHOLD) return result.best;

  const pool = [result.best];
  for (const { mv, score } of result.rootMoves) {
    if (moveEq(mv, result.best)) continue;
    if (result.score - score > variety) break;
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
D.HB = {
  search, bestMove, pickMove, evaluate, staticExchangeEval,
  hangsMovedPiece, MATE, MAX_DEPTH, VARIETY_MARGIN, ASPIRATION_WINDOW, F,
};

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { search, bestMove, pickMove, evaluate, staticExchangeEval };
}
})();
