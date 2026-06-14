import Foundation

// MARK: - Drott Engine
//
// A native Swift game-search engine for Drott. It reuses `Board` (the single
// source of truth for the rules) and applies the standard chess-engine search
// techniques — negamax with alpha-beta pruning, iterative deepening, and a
// capture-only quiescence search — paired with a Drott-specific evaluation.
//
// The three win conditions it understands:
//   1. capture the enemy king,
//   2. hold your king on the castle (F6) until your next turn,
//   3. occupy the enemy fort while they hold none of their own.
//
// Piece value is *mobility*: a piece is worth roughly the number of squares it
// can currently reach. Active pieces are valuable; boxed-in pieces are not.

struct SearchResult {
    var best: Move?
    var secondBest: Move?
    var score: Int        // best move's score, from the side-to-move's view
    var secondScore: Int
    var depth: Int        // depth of the last fully-completed iteration
}

/// Tracks how many times each position has occurred, across the real game
/// history plus the current search path, so the engine treats a move that
/// would complete a threefold repetition as a draw.
final class Repetition {
    private var counts: [UInt64: Int]

    init(_ boards: [Board]) {
        counts = [:]
        counts.reserveCapacity(boards.count * 2 + 16)
        for b in boards { counts[b.repetitionKey, default: 0] += 1 }
    }

    /// Increment the count for `key` and return the new total.
    func enter(_ key: UInt64) -> Int {
        let n = (counts[key] ?? 0) + 1
        counts[key] = n
        return n
    }

    func leave(_ key: UInt64) {
        if let n = counts[key], n > 1 { counts[key] = n - 1 } else { counts[key] = nil }
    }
}

// MARK: - Transposition table + search state

enum TTFlag { case exact, lower, upper }

struct TTEntry {
    var depth: Int
    var score: Int
    var flag: TTFlag
    var bestMove: Move?
}

/// Per-search mutable state: transposition table, killer moves, history
/// heuristic, repetition tracker, and the deadline. One per `Engine.search`.
final class SearchContext {
    let deadline: Date
    let rep: Repetition
    private let boardN: Int
    private let boardSq: Int   // N*N, precomputed for historyIndex
    var tt: [UInt64: TTEntry] = [:]
    private var killers: [Move?]                 // 2 slots per ply
    private var history: [Int]                   // [(fromSquare * sq) + toSquare]
    private var deadlineCheck = 0

    init(deadline: Date, rep: Repetition, boardN: Int) {
        self.deadline = deadline
        self.rep = rep
        self.boardN = boardN
        self.boardSq = boardN * boardN
        killers = Array(repeating: nil, count: (Engine.maxDepth + 2) * 2)
        history = Array(repeating: 0, count: boardSq * boardSq)
        tt.reserveCapacity(1 << 13)
    }

    /// Amortised deadline check. The mobility eval is heavy, so even ~100 nodes
    /// can take a meaningful fraction of a short budget — check often enough that
    /// a 0.03s self-play search doesn't overshoot into the hundreds of ms.
    private var lastTimedOut = false
    /// Sticky "deadline has passed" flag, read without side effects.
    var isExpired: Bool { lastTimedOut }
    func timedOut() -> Bool {
        if lastTimedOut { return true }                 // sticky once past deadline
        deadlineCheck &+= 1
        if deadlineCheck & 0x3F == 0, Date() >= deadline { lastTimedOut = true }
        return lastTimedOut
    }

    func killer(_ ply: Int, _ slot: Int) -> Move? {
        let i = ply * 2 + slot
        return i < killers.count ? killers[i] : nil
    }

    @inline(__always) private func historyIndex(_ m: Move) -> Int {
        (m.from.col + m.from.row * boardN) * boardSq + (m.to.col + m.to.row * boardN)
    }

    func historyScore(_ m: Move) -> Int { history[historyIndex(m)] }

    /// Record a beta cutoff: store quiet movers as killers and bump history.
    func recordCutoff(_ m: Move, ply: Int, depth: Int) {
        guard !m.isCapture else { return }
        let base = ply * 2
        if base + 1 < killers.count, killers[base] != m {
            killers[base + 1] = killers[base]
            killers[base] = m
        }
        history[historyIndex(m)] += depth * depth
    }
}

enum Engine {

    // Large terminal score; kept well below Int.max so ±mate arithmetic is safe.
    static let mate = 1_000_000
    static let infinity = 2_000_000
    static let maxDepth = 32

    /// Fixed material value per piece type = the squares it can reach on an open
    /// board (its "characteristic" mobility), scaled ×25 so a Skjolding ≈ 100
    /// (one "pawn"). This is stable, so a capture is always worth the captured
    /// piece's real value even when it is momentarily boxed in.
    static func baseValue(_ t: PieceType) -> Int {
        switch t {
        case .king:      return 0     // its loss is the terminal mate score
        case .skjolding: return 100   //  4 squares
        case .bowman:    return 150   //  6
        case .spearman:  return 175   //  7
        case .berserker: return 275   // 11
        case .hunter:    return 300   // 12
        case .wolf:      return 300   // 12
        case .elf:       return 500   // 20
        case .dwarf:     return 500   // 20
        }
    }

    /// Bonus per square a piece can reach *right now* (activity on top of the
    /// fixed base value). Small, so it differentiates active vs. passive pieces
    /// without swamping material.
    static let mobilityWeight = 3

    // How often, and within what margin, the engine plays the second-best move
    // instead of the best — just enough to break determinism without blundering.
    static let varietyProbability = 0.30
    static let varietyMargin = 30          // in eval units (~0.3 "pawns")

    // Scores at/above this magnitude are "mate" scores (win in N).
    static var mateThreshold: Int { mate - maxDepth - 1 }
    private static func isMateScore(_ s: Int) -> Bool { abs(s) > mateThreshold }

    // MARK: Public entry

    /// Full multi-line search: best and second-best root moves with their
    /// scores, plus the depth reached, via iterative deepening + a transposition
    /// table, killer/history move ordering, and principal-variation search.
    ///
    /// `history` is the sequence of real positions already played (ending at
    /// `board`); the engine uses it to score repetition draws correctly.
    /// `depthLimit` caps iterative deepening (e.g. 22 for deep analysis).
    static func search(_ board: Board, history: [Board] = [],
                       timeLimit: TimeInterval,
                       depthLimit: Int = maxDepth) -> SearchResult {
        let ctx = SearchContext(deadline: Date().addingTimeInterval(timeLimit),
                                rep: Repetition(history), boardN: board.N)
        var ordering = orderMoves(board.legalMoves(), board: board, ctx: ctx, ply: 0, ttMove: nil)

        guard !ordering.isEmpty else {
            return SearchResult(best: nil, secondBest: nil,
                                score: -mate, secondScore: -mate, depth: 0)
        }

        var result = SearchResult(best: ordering[0],
                                  secondBest: ordering.count > 1 ? ordering[1] : nil,
                                  score: -infinity, secondScore: -infinity, depth: 0)

        var depth = 1
        while depth <= min(depthLimit, maxDepth) {
            let iter = searchRoot(board, depth: depth, ordering: ordering, ctx: ctx)
            guard iter.completed else { break }   // ran out of time mid-iteration

            result.best = iter.best
            result.score = iter.bestScore
            result.secondBest = iter.second
            result.secondScore = iter.secondScore
            result.depth = depth

            ordering = iter.ordering               // best-first next iteration
            if isMateScore(iter.bestScore) && iter.bestScore > 0 { break }  // forced win
            depth += 1
        }
        return result
    }

    /// Convenience wrapper used by tests and simple callers.
    static func bestMove(for board: Board, timeLimit: TimeInterval) -> Move? {
        search(board, timeLimit: timeLimit).best
    }

    /// Pick a move from a result, occasionally choosing the second-best (when it
    /// is nearly as good) so play is not perfectly deterministic. A forced win is
    /// always taken; a second-best that loses is never chosen.
    static func pickMove(from r: SearchResult,
                         rng: () -> Double = { Double.random(in: 0..<1) }) -> Move? {
        guard let best = r.best else { return nil }
        guard let second = r.secondBest else { return best }
        if r.score >= mateThreshold { return best }            // take the win
        if r.secondScore <= -mateThreshold { return best }     // 2nd is a loss
        if r.score - r.secondScore <= varietyMargin, rng() < varietyProbability {
            return second
        }
        return best
    }

    // MARK: Root (principal-variation search, multi-line)

    private struct RootIteration {
        var best: Move
        var bestScore: Int
        var second: Move?
        var secondScore: Int
        var ordering: [Move]
        var completed: Bool
    }

    private static func searchRoot(_ board: Board, depth: Int,
                                   ordering: [Move], ctx: SearchContext) -> RootIteration {
        var alpha = -infinity
        let beta = infinity
        var scored: [(move: Move, score: Int)] = []
        scored.reserveCapacity(ordering.count)
        var best = ordering[0], bestScore = -infinity
        var completed = true

        for (i, mv) in ordering.enumerated() {
            if ctx.timedOut() { completed = false; break }
            let child = board.applying(mv)
            let key = child.repetitionKey
            let reps = ctx.rep.enter(key)
            var score: Int
            if reps >= 3 {
                score = 0
            } else if i == 0 {
                score = -negamax(child, key: key, depth: depth - 1,
                                 alpha: -beta, beta: -alpha, ply: 1, ctx: ctx)
            } else {
                score = -negamax(child, key: key, depth: depth - 1,
                                 alpha: -alpha - 1, beta: -alpha, ply: 1, ctx: ctx)
                if score > alpha {   // promising — re-search with a full window
                    score = -negamax(child, key: key, depth: depth - 1,
                                     alpha: -beta, beta: -alpha, ply: 1, ctx: ctx)
                }
            }
            ctx.rep.leave(key)
            scored.append((mv, score))
            if score > bestScore { bestScore = score; best = mv }
            if score > alpha { alpha = score }
        }

        // If the deadline passed at any point during this iteration (e.g. inside
        // the last move's search), its scores are unreliable — discard them.
        if ctx.isExpired { completed = false }

        // A partial iteration can still improve the move ordering, but its scores
        // are unreliable, so the caller discards it for the reported result.
        guard completed else {
            return RootIteration(best: best, bestScore: bestScore, second: nil,
                                 secondScore: -infinity, ordering: ordering, completed: false)
        }

        scored.sort { $0.score > $1.score }
        return RootIteration(
            best: scored[0].move, bestScore: scored[0].score,
            second: scored.count > 1 ? scored[1].move : nil,
            secondScore: scored.count > 1 ? scored[1].score : -infinity,
            ordering: scored.map { $0.move }, completed: true)
    }

    // MARK: Negamax + alpha-beta + TT + PVS

    private static func negamax(_ board: Board, key: UInt64, depth: Int,
                                alpha: Int, beta: Int, ply: Int, ctx: SearchContext) -> Int {
        if let w = board.winner {
            let s = mate - ply
            return w == board.sideToMove ? s : -s
        }

        var alpha = alpha
        var beta = beta
        let alphaOrig = alpha

        // Transposition-table probe.
        var ttMove: Move? = nil
        if let e = ctx.tt[key] {
            ttMove = e.bestMove
            if e.depth >= depth {
                switch e.flag {
                case .exact: return e.score
                case .lower: alpha = max(alpha, e.score)
                case .upper: beta = min(beta, e.score)
                }
                if alpha >= beta { return e.score }
            }
        }

        if depth <= 0 {
            // Quiescence searches only captures (irreversible), so a repetition
            // can never form there — no rep tracking needed below this point.
            return quiesce(board, alpha: alpha, beta: beta, ply: ply, ctx: ctx)
        }

        let moves = orderMoves(board.legalMoves(), board: board, ctx: ctx, ply: ply, ttMove: ttMove)
        if moves.isEmpty { return -(mate - ply) }   // immobility = loss

        var best = -infinity
        var bestMove: Move? = nil
        var searchedFirst = false

        let k0 = ctx.killer(ply, 0), k1 = ctx.killer(ply, 1)
        var moveIndex = 0
        for mv in moves {
            if ctx.timedOut() { break }
            let child = board.applying(mv)
            let childKey = child.repetitionKey
            let reps = ctx.rep.enter(childKey)
            var score: Int
            if reps >= 3 {
                score = 0
            } else if !searchedFirst {
                score = -negamax(child, key: childKey, depth: depth - 1,
                                 alpha: -beta, beta: -alpha, ply: ply + 1, ctx: ctx)
            } else {
                // Late move reduction: search likely-bad quiet moves shallower
                // first, and only re-search at full depth if they beat alpha.
                let quiet = !mv.isCapture && mv != k0 && mv != k1
                let reduction = (depth >= 3 && moveIndex >= 3 && quiet) ? 1 : 0

                score = -negamax(child, key: childKey, depth: depth - 1 - reduction,
                                 alpha: -alpha - 1, beta: -alpha, ply: ply + 1, ctx: ctx)
                if reduction > 0 && score > alpha {       // reduced search looked good
                    score = -negamax(child, key: childKey, depth: depth - 1,
                                     alpha: -alpha - 1, beta: -alpha, ply: ply + 1, ctx: ctx)
                }
                if score > alpha && score < beta {        // raise → full-window re-search
                    score = -negamax(child, key: childKey, depth: depth - 1,
                                     alpha: -beta, beta: -alpha, ply: ply + 1, ctx: ctx)
                }
            }
            ctx.rep.leave(childKey)
            searchedFirst = true
            moveIndex += 1

            if score > best { best = score; bestMove = mv }
            if best > alpha { alpha = best }
            if alpha >= beta {
                ctx.recordCutoff(mv, ply: ply, depth: depth)   // killer + history
                break
            }
        }

        // Store in the transposition table (skip unstable mate scores).
        if !ctx.timedOut() && !isMateScore(best) {
            let flag: TTFlag = best <= alphaOrig ? .upper : (best >= beta ? .lower : .exact)
            ctx.tt[key] = TTEntry(depth: depth, score: best, flag: flag, bestMove: bestMove)
        }
        return best
    }

    // MARK: Quiescence search
    //
    // Extends the search along captures only, so the static evaluation is never
    // applied in the middle of an unresolved exchange (the "horizon effect").
    // Critical here because capturing the king ends the game immediately.

    private static func quiesce(_ board: Board, alpha: Int, beta: Int,
                                ply: Int, ctx: SearchContext) -> Int {
        if let w = board.winner {
            let s = mate - ply
            return w == board.sideToMove ? s : -s
        }

        let standPat = evaluate(board, for: board.sideToMove)
        if standPat >= beta { return beta }
        var alpha = max(alpha, standPat)
        if ply >= maxDepth { return alpha }

        for mv in orderMoves(board.captureMoves(), board: board, ctx: ctx, ply: ply, ttMove: nil) {
            if ctx.timedOut() { break }
            let child = board.applying(mv)
            let score = -quiesce(child, alpha: -beta, beta: -alpha, ply: ply + 1, ctx: ctx)
            if score >= beta { return beta }
            if score > alpha { alpha = score }
        }
        return alpha
    }

    // MARK: Move ordering
    //
    // Ordering quality drives pruning. Priority: TT move, then captures by victim
    // value (MVV), then the two killer moves for this ply, then quiet moves by
    // the history-heuristic score.

    private static func orderMoves(_ moves: [Move], board: Board, ctx: SearchContext,
                                   ply: Int, ttMove: Move?) -> [Move] {
        let k0 = ctx.killer(ply, 0)
        let k1 = ctx.killer(ply, 1)
        return moves.sorted {
            orderKey($0, board: board, ctx: ctx, ttMove: ttMove, k0: k0, k1: k1)
                > orderKey($1, board: board, ctx: ctx, ttMove: ttMove, k0: k0, k1: k1)
        }
    }

    private static func orderKey(_ mv: Move, board: Board, ctx: SearchContext,
                                 ttMove: Move?, k0: Move?, k1: Move?) -> Int {
        if let t = ttMove, mv == t { return 1_000_000_000 }
        if mv.isCapture, let victim = board.piece(at: mv.to) {
            if victim.type == .king { return 900_000_000 }
            // MVV-LVA: prefer taking the most valuable victim with the least
            // valuable attacker, so winning captures are searched first.
            let attacker = board.piece(at: mv.from)?.type ?? .skjolding
            return 500_000_000 + baseValue(victim.type) * 16 - baseValue(attacker)
        }
        if let k = k0, mv == k { return 400_000_000 }
        if let k = k1, mv == k { return 399_000_000 }
        return ctx.historyScore(mv)
    }

    // MARK: Evaluation
    //
    // Static score from `me`'s perspective (positive = good for `me`). Symmetric:
    // every term is added for `me` and subtracted for the opponent.
    //
    // Piece value = a fixed base (its characteristic open-board reach) plus a
    // small bonus for its current reach. The base keeps captures correctly
    // valued even when a piece is momentarily boxed in; the bonus rewards
    // activity. Win-condition terms (king/castle/fort) sit on top.

    static func evaluate(_ board: Board, for me: Side) -> Int {
        let opp = me.other
        var score = 0

        var myKing: Position?
        var oppKing: Position?
        var myFortDefenders = 0
        var oppFortDefenders = 0
        var myInOppFort = 0
        var oppInMyFort = 0

        for sq in board.squares {
            guard let p = sq else { continue }
            let sgn = p.side == me ? 1 : -1

            // Material = fixed base value for the piece type, plus a small bonus
            // for the squares it can currently reach (activity).
            score += sgn * (baseValue(p.type) + board.mobilityCount(for: p) * mobilityWeight)

            // Skjolding advancement toward the enemy.
            if p.type == .skjolding {
                let advance = p.side == .red ? p.pos.row : (board.N - 1 - p.pos.row)
                score += sgn * advance * 4
            }

            if p.type == .king {
                if p.side == me { myKing = p.pos } else { oppKing = p.pos }
            }

            // Fort bookkeeping.
            if board.isFort(p.pos, for: p.side) {
                if p.side == me { myFortDefenders += 1 } else { oppFortDefenders += 1 }
            }
            if p.side == me  && board.isFort(p.pos, for: opp) { myInOppFort += 1 }
            if p.side == opp && board.isFort(p.pos, for: me)  { oppInMyFort += 1 }
        }

        let castlePos = board.castle

        // Win condition 2 — king toward / on the castle. A king already on the
        // castle is a standing threat to win next turn (the search resolves
        // whether the opponent can capture or dislodge it).
        if let k = myKing {
            score += (k == castlePos) ? 5000 : (5 - k.chebyshev(to: castlePos)) * 6
        }
        if let k = oppKing {
            score -= (k == castlePos) ? 5000 : (5 - k.chebyshev(to: castlePos)) * 6
        }

        // Win condition 3 — fort attack and defense.
        score += myInOppFort * 200
        score -= oppInMyFort * 200
        if myInOppFort  > 0 && oppFortDefenders == 0 { score += 6000 }  // nearly won
        if oppInMyFort  > 0 && myFortDefenders  == 0 { score -= 6000 }  // nearly lost
        score += myFortDefenders  > 0 ? 120 : 0   // keep a defender at home
        score -= oppFortDefenders > 0 ? 120 : 0

        return score
    }
}
