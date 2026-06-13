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
        edgeProbing()
        kingCaptureTerminal()
        kingCaptureTactic()
        fortControl()
        castleHold()
        dragMath()
        engineSanity()
        selfPlayStress()

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

    // Generating moves for every piece type on every square must never read
    // off-board (regression for the array-indexed piece(at:) crash). The rules
    // probe neighbouring squares without bounds-checking, so edges and corners
    // — where a forward/knight probe lands outside the board — are the risk.
    private static func edgeProbing() {
        print("[edge probing]")
        var combos = 0
        for type in PieceType.allCases {
            for side in Side.allCases {
                for row in 0..<Board.N {
                    for col in 0..<Board.N {
                        var b = Board.empty()
                        b.put(.king, .red, Position(col: 0, row: 0))
                        b.put(.king, .black, Position(col: 10, row: 10))
                        b.put(type, side, Position(col: col, row: row))
                        b.sideToMove = side
                        _ = b.legalMoves()    // would trap on an off-board probe
                        _ = b.captureMoves()
                        combos += 1
                    }
                }
            }
        }
        // Reaching here means no out-of-bounds access occurred.
        check(combos == PieceType.allCases.count * 2 * Board.N * Board.N,
              "move-gen safe for every piece on every square (\(combos) combos)")
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

    // Drag-and-drop coordinate mapping: a drop's target square must match the
    // cursor offset, accounting for screen-y-down vs board-row-up.
    private static func dragMath() {
        print("[drag math]")
        let from = Position(col: 5, row: 1)   // F2
        // Two squares right and two squares "up" the board = screen up (-y).
        let up = GameState.dropTarget(from: from, translation: CGSize(width: 2 * SQ, height: -2 * SQ))
        check(up == Position(col: 7, row: 3), "drag up-right lands on H4 (got \(up))")
        // One square left and one "down" the board = screen down (+y).
        let down = GameState.dropTarget(from: from, translation: CGSize(width: -SQ, height: SQ))
        check(down == Position(col: 4, row: 0), "drag down-left lands on E1 (got \(down))")
        // A tiny jiggle stays on the same square.
        let stay = GameState.dropTarget(from: from, translation: CGSize(width: 5, height: -4))
        check(stay == from, "small jiggle stays put (got \(stay))")
    }

    // The engine returns a legal move on the opening within the time budget,
    // and reaches a usable search depth despite the expensive mobility eval.
    private static func engineSanity() {
        print("[engine sanity]")
        let b = Board()
        let start = Date()
        let result = Engine.search(b, timeLimit: 1.2)
        let elapsed = Date().timeIntervalSince(start)
        check(result.best != nil, "engine returns a move on the opening")
        if let mv = result.best {
            let legal = b.legalMoves().contains(mv)
            check(legal, "engine's move is legal (\(b.notation(for: mv)))")
        }
        check(result.secondBest != nil, "engine produced a second line")
        check(result.depth >= 2, "reached usable depth (\(result.depth)) in \(String(format: "%.2f", elapsed))s")
        check(elapsed < 3.5, "search respected the time budget (\(String(format: "%.2f", elapsed))s)")
    }

    // Play a full computer-vs-computer game to completion. Reproduces the real
    // self-play scenario that crashed (engine searching evolving positions with
    // pieces pushed to the board edges).
    private static func selfPlayStress() {
        print("[self-play stress]")
        var b = Board()
        var moves = 0
        let cap = 150
        while b.winner == nil && moves < cap {
            guard let mv = Engine.bestMove(for: b, timeLimit: 0.03) else { break }
            b = b.applying(mv)
            moves += 1
        }
        let outcome = b.winner.map { $0.rawValue } ?? "no result (move cap)"
        check(moves > 0, "self-play ran \(moves) moves without crashing — \(outcome)")
    }
}
