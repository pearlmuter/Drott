import Foundation

// MARK: - Headless self-test
//
// Run with `DROTT_SELFTEST=1 swift run` to exercise the rules engine and AI
// without launching the GUI. Exits 0 on success, 1 on the first failure.

extension Board {
    /// A board with no pieces (for constructing test positions).
    static func empty() -> Board {
        var b = Board()
        b.squares = Array(repeating: nil, count: Board.N * Board.N)
        b.castleWinPending = nil
        b.winner = nil
        b.winReason = nil
        return b
    }

    mutating func put(_ t: PieceType, _ s: Side, _ p: Position) {
        squares[index(p)] = Piece(type: t, side: s, pos: p)
    }
}

enum SelfTest {

    private static var failures = 0

    private static func check(_ cond: Bool, _ label: String) {
        if cond {
            print("  PASS  \(label)")
        } else {
            print("  FAIL  \(label)")
            failures += 1
        }
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["DROTT_SELFTEST"] == "1" else { return }
        print("=== Drott self-test ===")

        startPosition()
        kingCaptureTerminal()
        kingCaptureTactic()
        fortControl()
        castleHold()
        engineSanity()

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    // The opening position should have a sane set of moves for both sides.
    private static func startPosition() {
        print("[start position]")
        var b = Board()
        let red = b.legalMoves()
        check(!red.isEmpty, "red has opening moves (\(red.count))")
        b.sideToMove = .black
        let black = b.legalMoves()
        check(red.count == black.count, "opening is symmetric (red \(red.count) == black \(black.count))")
        check(b.winner == nil, "opening is not terminal")
    }

    // Capturing the enemy king ends the game for the mover.
    private static func kingCaptureTerminal() {
        print("[king-capture terminal]")
        var b = Board.empty()
        b.put(.king, .red, Position(col: 0, row: 0))     // A1
        b.put(.king, .black, Position(col: 2, row: 2))   // C3
        b.put(.wolf, .red, Position(col: 2, row: 0))     // C1 — slides to C3
        b.sideToMove = .red
        let after = b.applying(Move(from: Position(col: 2, row: 0),
                                    to: Position(col: 2, row: 2), isCapture: true))
        check(after.winner == .red, "red wins by capturing black king")
        check(after.winReason == .kingCapture, "win reason is kingCapture")
    }

    // The engine should find a one-move king capture when one exists.
    private static func kingCaptureTactic() {
        print("[king-capture tactic]")
        var b = Board.empty()
        b.put(.king, .red, Position(col: 0, row: 0))     // A1
        b.put(.king, .black, Position(col: 2, row: 2))   // C3
        b.put(.wolf, .red, Position(col: 2, row: 0))     // C1
        // A couple of decoys so the capture isn't the only move.
        b.put(.skjolding, .red, Position(col: 9, row: 0))
        b.put(.skjolding, .black, Position(col: 9, row: 10))
        b.sideToMove = .red
        let best = Engine.bestMove(for: b, timeLimit: 1.0)
        check(best?.to == Position(col: 2, row: 2), "engine plays the king capture (got \(best.map { "\($0.from)-\($0.to)" } ?? "nil"))")
    }

    // Fort control: a piece in the enemy fort while they hold none of their own.
    private static func fortControl() {
        print("[fort control]")
        var b = Board.empty()
        b.put(.king, .red, Position(col: 0, row: 0))
        b.put(.king, .black, Position(col: 10, row: 10))
        // Red skjolding sitting on a black-fort square (D11).
        b.put(.skjolding, .red, Position(col: 3, row: 10))
        check(b.checkFortWin() == .red, "red controls empty black fort")

        // Add a black defender to its own fort → no win.
        b.put(.skjolding, .black, Position(col: 4, row: 10))  // E11
        check(b.checkFortWin() == nil, "black defending its fort denies the win")
    }

    // Castle hold: king on F6 survives the opponent's reply and wins next turn.
    private static func castleHold() {
        print("[castle hold]")
        var b = Board.empty()
        b.put(.king, .red, Position(col: 4, row: 5))     // E6, next to castle
        b.put(.king, .black, Position(col: 10, row: 10))
        b.put(.skjolding, .black, Position(col: 0, row: 10)) // A11 — has a reply
        b.sideToMove = .red

        let onCastle = b.applying(Move(from: Position(col: 4, row: 5),
                                       to: Position(col: 5, row: 5), isCapture: false))
        check(onCastle.castleWinPending == .red, "castle hold registered as pending")
        check(onCastle.winner == nil, "not won immediately on entering the castle")
        check(onCastle.sideToMove == .black, "turn passes to black")

        // Black makes any move; red should then win by holding the castle.
        let blackMove = onCastle.legalMoves().first!
        let resolved = onCastle.applying(blackMove)
        check(resolved.winner == .red, "red wins by holding the castle after black's reply")
        check(resolved.winReason == .castle, "win reason is castle")
    }

    // The engine returns a legal move on the opening within the time budget.
    private static func engineSanity() {
        print("[engine sanity]")
        let b = Board()
        let start = Date()
        let best = Engine.bestMove(for: b, timeLimit: 1.0)
        let elapsed = Date().timeIntervalSince(start)
        check(best != nil, "engine returns a move on the opening")
        if let mv = best {
            let legal = b.legalMoves().contains(mv)
            check(legal, "engine's move is legal (\(mv.from)-\(mv.to))")
        }
        check(elapsed < 3.0, "search respected the time budget (\(String(format: "%.2f", elapsed))s)")
    }
}
