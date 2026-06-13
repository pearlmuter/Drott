import Foundation

// MARK: - Drott Engine
//
// A native Swift game-search engine for Drott. It reuses `Board` (the single
// source of truth for the rules) and applies the standard chess-engine search
// techniques — negamax with alpha-beta pruning, iterative deepening, and a
// capture-only quiescence search — paired with a Drott-specific evaluation
// function that understands the three win conditions:
//
//   1. capture the enemy king,
//   2. hold your king on the castle (F6) until your next turn,
//   3. occupy the enemy fort while they hold none of their own.
//
// Search values are in "centipawn-like" units (a Skjolding ≈ 100).

enum Engine {

    // Large terminal score; kept well below Int.max so ±MATE arithmetic is safe.
    static let mate = 1_000_000
    static let infinity = 2_000_000
    static let maxDepth = 32

    // Material values. The king is 0 here — its loss is the terminal `mate`
    // score, and it is always present in any non-terminal position, so it never
    // contributes to the relative evaluation.
    static func value(_ t: PieceType) -> Int {
        switch t {
        case .king:      return 0
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

    /// Best move for the side to move in `board`, searched within `timeLimit`
    /// seconds via iterative deepening. Returns nil only if there are no moves.
    static func bestMove(for board: Board, timeLimit: TimeInterval) -> Move? {
        let deadline = Date().addingTimeInterval(timeLimit)
        let rootMoves = ordered(board.legalMoves(), on: board)
        guard !rootMoves.isEmpty else { return nil }

        var best = rootMoves[0]
        var depth = 1

        while depth <= maxDepth {
            var alpha = -infinity
            let beta = infinity
            var localBest = rootMoves[0]
            var completed = true

            // Search the previous iteration's best move first.
            var moves = rootMoves
            if let i = moves.firstIndex(of: best) {
                moves.remove(at: i); moves.insert(best, at: 0)
            }

            for mv in moves {
                if Date() >= deadline { completed = false; break }
                let child = board.applying(mv)
                let score = -negamax(child, depth: depth - 1, alpha: -beta,
                                     beta: -alpha, ply: 1, deadline: deadline)
                if score > alpha {
                    alpha = score
                    localBest = mv
                }
            }

            if completed {
                best = localBest
                // A forced win is found — no point searching deeper.
                if alpha >= mate - maxDepth { break }
            } else {
                break
            }
            depth += 1
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
        moves.sorted { score($0, on: board) > score($1, on: board) }
    }

    private static func score(_ mv: Move, on board: Board) -> Int {
        guard mv.isCapture, let victim = board.piece(at: mv.to) else { return 0 }
        if victim.type == .king { return 1_000_000 }
        return 10_000 + value(victim.type)
    }

    // MARK: Evaluation
    //
    // Static score from `me`'s perspective (positive = good for `me`). Symmetric:
    // every term is added for `me` and subtracted for the opponent.

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

            // Material.
            score += sgn * value(p.type)

            // Skjolding advancement toward the enemy.
            if p.type == .skjolding {
                let advance = p.side == .red ? p.pos.row : (10 - p.pos.row)
                score += sgn * advance * 4
            }

            // Centre activity (closer to F6 is worth more).
            let centre = max(0, 5 - p.pos.chebyshev(to: .castle))
            score += sgn * centre * 3

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
