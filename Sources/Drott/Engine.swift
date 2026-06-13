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

enum Engine {

    // Large terminal score; kept well below Int.max so ±mate arithmetic is safe.
    static let mate = 1_000_000
    static let infinity = 2_000_000
    static let maxDepth = 32

    /// How much a square of mobility is worth (scales the whole eval so that
    /// ~one piece of mobility advantage ≈ 0.04 "pawns" in the display).
    static let mobilityWeight = 4

    // How often, and within what margin, the engine plays the second-best move
    // instead of the best — just enough to break determinism without blundering.
    static let varietyProbability = 0.30
    static let varietyMargin = 30          // in eval units (~0.3 "pawns")

    // Static piece ranks used ONLY for capture move-ordering (cheap, need not
    // match the mobility evaluation). King highest so king-captures sort first.
    private static func orderingValue(_ t: PieceType) -> Int {
        switch t {
        case .king:      return 10_000
        case .skjolding: return 100
        case .spearman:  return 240
        case .hunter:    return 280
        case .bowman:    return 290
        case .dwarf:     return 300
        case .wolf:      return 320
        case .elf:       return 330
        case .berserker: return 340
        }
    }

    // MARK: Public entry

    /// Full multi-line search: returns the best and second-best root moves with
    /// their exact scores, plus the depth reached, via iterative deepening.
    ///
    /// Root moves are searched with a full window (no sibling pruning) so every
    /// root score is exact — that is what makes the second-best reliable and the
    /// evaluation read-out meaningful. Pruning still applies one level down.
    static func search(_ board: Board, timeLimit: TimeInterval) -> SearchResult {
        let deadline = Date().addingTimeInterval(timeLimit)
        var ordering = ordered(board.legalMoves(), on: board)

        guard !ordering.isEmpty else {
            return SearchResult(best: nil, secondBest: nil,
                                score: -(mate), secondScore: -(mate), depth: 0)
        }

        var result = SearchResult(best: ordering[0], secondBest: ordering.count > 1 ? ordering[1] : nil,
                                  score: -infinity, secondScore: -infinity, depth: 0)
        var depth = 1

        while depth <= maxDepth {
            var scored: [(move: Move, score: Int)] = []
            var completed = true

            for mv in ordering {
                if Date() >= deadline { completed = false; break }
                let child = board.applying(mv)
                let s = -negamax(child, depth: depth - 1, alpha: -infinity,
                                 beta: infinity, ply: 1, deadline: deadline)
                scored.append((mv, s))
            }

            // Only adopt a depth that finished — a partial sweep is unreliable.
            guard completed else { break }

            scored.sort { $0.score > $1.score }
            result.best = scored[0].move
            result.score = scored[0].score
            if scored.count > 1 {
                result.secondBest = scored[1].move
                result.secondScore = scored[1].score
            } else {
                result.secondBest = nil
                result.secondScore = -infinity
            }
            result.depth = depth

            ordering = scored.map { $0.move }       // best-first next iteration
            if result.score >= mate - maxDepth { break }   // forced win found
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
        if r.score >= mate - maxDepth { return best }              // take the win
        if r.secondScore <= -(mate - maxDepth) { return best }     // 2nd is a loss
        if r.score - r.secondScore <= varietyMargin, rng() < varietyProbability {
            return second
        }
        return best
    }

    // MARK: Negamax + alpha-beta

    private static func negamax(_ board: Board, depth: Int, alpha: Int, beta: Int,
                                ply: Int, deadline: Date) -> Int {
        if let w = board.winner {
            // `applying` always switches the side to move, so a terminal node's
            // sideToMove is the player about to move into the decided result.
            let s = mate - ply
            return w == board.sideToMove ? s : -s
        }
        if depth <= 0 {
            return quiesce(board, alpha: alpha, beta: beta, ply: ply, deadline: deadline)
        }

        var alpha = alpha
        let moves = ordered(board.legalMoves(), on: board)
        if moves.isEmpty {
            // No legal move: treat immobility as a loss for the side to move.
            return -(mate - ply)
        }

        var best = -infinity
        for mv in moves {
            if Date() >= deadline { break }
            let child = board.applying(mv)
            let score = -negamax(child, depth: depth - 1, alpha: -beta,
                                 beta: -alpha, ply: ply + 1, deadline: deadline)
            if score > best { best = score }
            if best > alpha { alpha = best }
            if alpha >= beta { break }   // beta cutoff
        }
        return best
    }

    // MARK: Quiescence search
    //
    // Extends the search along captures only, so the static evaluation is never
    // applied in the middle of an unresolved exchange (the "horizon effect").
    // Critical here because capturing the king ends the game immediately.

    private static func quiesce(_ board: Board, alpha: Int, beta: Int,
                                ply: Int, deadline: Date) -> Int {
        if let w = board.winner {
            let s = mate - ply
            return w == board.sideToMove ? s : -s
        }

        let standPat = evaluate(board, for: board.sideToMove)
        if standPat >= beta { return beta }
        var alpha = max(alpha, standPat)

        if ply >= maxDepth { return alpha }

        for mv in ordered(board.captureMoves(), on: board) {
            if Date() >= deadline { break }
            let child = board.applying(mv)
            let score = -quiesce(child, alpha: -beta, beta: -alpha,
                                 ply: ply + 1, deadline: deadline)
            if score >= beta { return beta }
            if score > alpha { alpha = score }
        }
        return alpha
    }

    // MARK: Move ordering
    //
    // Good ordering makes alpha-beta prune far more. Captures first, most
    // valuable victim first (king highest of all), quiet moves after.

    private static func ordered(_ moves: [Move], on board: Board) -> [Move] {
        moves.sorted { orderingScore($0, on: board) > orderingScore($1, on: board) }
    }

    private static func orderingScore(_ mv: Move, on board: Board) -> Int {
        guard mv.isCapture, let victim = board.piece(at: mv.to) else { return 0 }
        if victim.type == .king { return 1_000_000 }
        return 10_000 + orderingValue(victim.type)
    }

    // MARK: Evaluation
    //
    // Static score from `me`'s perspective (positive = good for `me`). Symmetric:
    // every term is added for `me` and subtracted for the opponent.
    //
    // Piece value IS mobility: each piece contributes the number of squares it
    // can reach, scaled by `mobilityWeight`. Material and activity therefore fall
    // out of the same term — a trapped Wolf is worth little, a free one a lot.

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

            // Material = mobility (squares this piece can currently reach).
            let (m, a) = board.validDestinations(for: p)
            score += sgn * (m.count + a.count) * mobilityWeight

            // Skjolding advancement toward the enemy.
            if p.type == .skjolding {
                let advance = p.side == .red ? p.pos.row : (10 - p.pos.row)
                score += sgn * advance * 4
            }

            if p.type == .king {
                if p.side == me { myKing = p.pos } else { oppKing = p.pos }
            }

            // Fort bookkeeping.
            if Position.isFort(p.pos, for: p.side) {
                if p.side == me { myFortDefenders += 1 } else { oppFortDefenders += 1 }
            }
            if p.side == me  && Position.isFort(p.pos, for: opp) { myInOppFort += 1 }
            if p.side == opp && Position.isFort(p.pos, for: me)  { oppInMyFort += 1 }
        }

        // Win condition 2 — king toward / on the castle.
        if let k = myKing {
            score += (k == .castle) ? 4000 : (5 - k.chebyshev(to: .castle)) * 6
        }
        if let k = oppKing {
            score -= (k == .castle) ? 4000 : (5 - k.chebyshev(to: .castle)) * 6
        }
        if board.castleWinPending == me  { score += 8000 }
        if board.castleWinPending == opp { score -= 8000 }

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
