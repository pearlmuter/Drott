import Foundation

// MARK: - Headless self-test
//
// Run with `DROTT_SELFTEST=1 swift run` to exercise the rules engine and AI
// without launching the GUI. Exits 0 on success, 1 on the first failure.

extension Board {
    /// A board with no pieces (for constructing test positions).
    static func empty(size: BoardSize = .nine) -> Board {
        var b = Board(size: size)
        b.squares = Array(repeating: nil, count: b.N * b.N)
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
        fortTiming()
        hunterBoxedIn()
        freeCapture()
        threefold()
        repetitionAwareEngine()
        depthCap()
        startFlow()
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
        let n = Board().N   // test the default board size
        var combos = 0
        for type in PieceType.allCases {
            for side in Side.allCases {
                for row in 0..<n {
                    for col in 0..<n {
                        var b = Board.empty()
                        b.put(.king, .red,   Position(col: 0,     row: 0))
                        b.put(.king, .black, Position(col: n - 1, row: n - 1))
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
        check(combos == PieceType.allCases.count * 2 * n * n,
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
        b.put(.skjolding, .red, Position(col: 7, row: 0))
        b.put(.skjolding, .black, Position(col: 7, row: 8))
        b.sideToMove = .red
        let best = Engine.bestMove(for: b, timeLimit: 1.0)
        check(best?.to == Position(col: 2, row: 2), "engine plays the king capture (got \(best.map { "\($0.from)-\($0.to)" } ?? "nil"))")
    }

    // Fort control predicate: a piece in the enemy fort while they hold none.
    private static func fortControl() {
        print("[fort control]")
        var b = Board.empty()
        b.put(.king, .red,   Position(col: 0, row: 0))
        b.put(.king, .black, Position(col: 8, row: 8))
        b.put(.skjolding, .red, Position(col: 3, row: 8))   // red on D9 (black fort in 9×9)
        check(b.hasFortControl(.red), "red controls empty black fort")
        check(!b.hasFortControl(.black), "black does not control red's fort")

        b.put(.skjolding, .black, Position(col: 4, row: 8)) // E9 defender
        check(!b.hasFortControl(.red), "a black defender denies red's fort control")
    }

    // Castle hold: king on the castle square is NOT an immediate win — it wins
    // only once it becomes Red's turn again with the king still there.
    private static func castleHold() {
        print("[castle hold]")
        var b = Board.empty()
        // 9×9 castle = E5 = (4,4); place king one step to the left at D5 = (3,4)
        b.put(.king, .red, Position(col: 3, row: 4))     // D5, next to castle
        b.put(.king, .black, Position(col: 8, row: 8))   // far corner
        b.put(.skjolding, .black, Position(col: 0, row: 8)) // A9 — has a reply
        b.sideToMove = .red
        let castlePos = b.castle    // (4,4) for 9×9

        let onCastle = b.applying(Move(from: Position(col: 3, row: 4),
                                       to: castlePos, isCapture: false))
        check(onCastle.winner == nil, "not won immediately on entering the castle")
        check(onCastle.piece(at: castlePos)?.side == .red, "red king reached the castle")
        check(onCastle.sideToMove == .black, "turn passes to black")

        // Black replies harmlessly; red then wins by still holding the castle.
        let blackMove = onCastle.legalMoves().first!
        let resolved = onCastle.applying(blackMove)
        check(resolved.winner == .red, "red wins by holding the castle after black's reply")
        check(resolved.winReason == .castle, "win reason is castle")
    }

    // Win timing: entering the enemy fort is not an immediate win, and the
    // opponent can deny it by capturing the intruder before it survives a turn.
    private static func fortTiming() {
        print("[fort timing]")
        // 9×9 black fort: rows 7-8, cols 2-6. Use D9=(3,8) as the entry square.
        let wolfStart = Position(col: 3, row: 5)   // D6, 3 rows from D9
        let d9 = Position(col: 3, row: 8)          // D9, black fort in 9×9
        let wolfIn = Move(from: wolfStart, to: d9, isCapture: false)

        // Denial by capture: a Black king on C9 can take the intruder.
        var denied = Board.empty()
        denied.put(.king, .red, Position(col: 0, row: 0))
        denied.put(.wolf, .red, wolfStart)
        denied.put(.king, .black, Position(col: 2, row: 8))  // C9, adjacent to D9
        denied.sideToMove = .red
        let entered = denied.applying(wolfIn)
        check(entered.winner == nil, "entering the fort is not an immediate win")
        let capture = entered.applying(Move(from: Position(col: 2, row: 8), to: d9, isCapture: true))
        check(capture.winner == nil, "opponent denies the fort by capturing the intruder")

        // Survival: with no Black piece able to reach D9, Red wins next turn.
        var survives = Board.empty()
        survives.put(.king, .red, Position(col: 0, row: 0))
        survives.put(.wolf, .red, wolfStart)
        survives.put(.king, .black, Position(col: 8, row: 0))   // far away at I1
        survives.put(.skjolding, .black, Position(col: 0, row: 6)) // a harmless reply at A7
        survives.sideToMove = .red
        let in2 = survives.applying(wolfIn)
        check(in2.winner == nil, "still not won the instant the fort is entered")
        let reply = in2.applying(in2.legalMoves().first!)
        check(reply.winner == .red && reply.winReason == .fort,
              "Red wins by holding the fort through Black's reply")
    }

    // A free capture of a more valuable, momentarily boxed-in piece must be
    // taken (the bug behind the bowman the engine refused to win). The Black
    // Bowman on E6 is hemmed in (a Red Skjolding in front, the castle beside it)
    // so its *current* mobility is low — but its base value still exceeds a
    // Skjolding's, so the capture should win material.
    private static func freeCapture() {
        print("[free capture]")
        var b = Board.empty()
        b.put(.king, .red, Position(col: 0, row: 0))
        b.put(.king, .black, Position(col: 8, row: 8))
        b.put(.bowman, .black, Position(col: 4, row: 5))     // E6
        b.put(.skjolding, .red, Position(col: 4, row: 4))    // E5, blocks the bowman
        b.put(.skjolding, .red, Position(col: 3, row: 4))    // D5, can take E6 diagonally
        b.put(.skjolding, .red, Position(col: 7, row: 3))    // H4, a quiet alternative
        b.sideToMove = .red

        let best = Engine.bestMove(for: b, timeLimit: 0.5)
        check(best?.to == Position(col: 4, row: 5),
              "engine captures the boxed-in Bowman (got \(best.map { b.notation(for: $0) } ?? "nil"))")
    }

    // The Hunter cannot jump: at the start it is boxed in by its own pieces and
    // must not leap out between the Skjoldings.
    private static func hunterBoxedIn() {
        print("[hunter boxed in]")
        let b = Board()   // 9×9 default
        let hunter = b.piece(at: Position(col: 6, row: 0))!   // red Hunter at G1 in 9×9
        check(hunter.type == .hunter, "found the Hunter at G1")
        let (m, a) = b.validDestinations(for: hunter)
        let h3 = Position(col: 7, row: 2)   // would require leaping over H1/G2
        let i2 = Position(col: 8, row: 1)   // would require leaping over H1
        check(!m.contains(h3) && !a.contains(h3), "Hunter does not leap to H3 at the start")
        check(!m.contains(i2) && !a.contains(i2), "Hunter does not leap to I2 at the start")
        check(m.isEmpty && a.isEmpty, "Hunter is fully boxed in at the start")
    }

    // A position seen three times is a draw. Two kings shuffle a 4-ply cycle
    // twice; the start position then occurs at plies 0, 4, 8 → threefold at 8.
    private static func threefold() {
        print("[threefold repetition]")
        var b = Board.empty()
        b.put(.king, .red, Position(col: 0, row: 0))    // A1
        b.put(.king, .black, Position(col: 8, row: 8))  // I9 (far corner in 9×9)
        b.sideToMove = .red

        let cycle = [
            Move(from: Position(col: 0, row: 0), to: Position(col: 1, row: 0), isCapture: false),
            Move(from: Position(col: 8, row: 8), to: Position(col: 7, row: 8), isCapture: false),
            Move(from: Position(col: 1, row: 0), to: Position(col: 0, row: 0), isCapture: false),
            Move(from: Position(col: 7, row: 8), to: Position(col: 8, row: 8), isCapture: false),
        ]

        var history = [b]
        var drawAt: Int? = nil
        for _ in 0..<2 {
            for mv in cycle {
                b = b.applying(mv)
                history.append(b)
                if drawAt == nil, GameState.isThreefoldRepetition(in: history) {
                    drawAt = history.count - 1
                }
            }
        }
        check(drawAt == 8, "threefold detected at ply 8 (got \(drawAt.map(String.init) ?? "nil"))")

        // A position seen only twice is not yet a draw.
        let twice = Array(history.prefix(5))   // start seen at 0 and 4
        check(!GameState.isThreefoldRepetition(in: twice), "twice-seen position is not a draw")
    }

    // The engine treats a move into a thrice-seen position as a draw. A losing
    // side (down a Wolf, kings far apart so there are no tactics) should grab
    // that draw when the history makes it available.
    private static func repetitionAwareEngine() {
        print("[repetition-aware engine]")
        let redKing = Position(col: 5, row: 2)   // F3, central & safe (valid in 9×9)
        let redWolf = Position(col: 5, row: 5)   // F6 (valid in 9×9)
        let blackA9 = Position(col: 0, row: 8)   // A9 corner, far from Red
        let blackB9 = Position(col: 1, row: 8)   // B9

        // Root: Black to move, down a Wolf, no tactics available either way.
        var root = Board.empty()
        root.put(.king, .red, redKing)
        root.put(.wolf, .red, redWolf)
        root.put(.king, .black, blackA9)
        root.sideToMove = .black

        // The position after Black shuffles A9–B9 (Red to move).
        var child = Board.empty()
        child.put(.king, .red, redKing)
        child.put(.wolf, .red, redWolf)
        child.put(.king, .black, blackB9)
        child.sideToMove = .red

        // Without history, Black is losing (Red marches the Wolf into Black's
        // undefended fort).
        let losing = Engine.search(root, history: [root], timeLimit: 0.3)
        check(losing.score < 0, "without history Black is losing (\(losing.score))")

        // With `child` already seen twice, A9–B9 completes a threefold → a draw
        // the engine prefers to the losing line.
        let saved = Engine.search(root, history: [child, child, root], timeLimit: 0.3)
        check(saved.score == 0, "engine claims the repetition draw (score \(saved.score))")
        check(saved.score > losing.score, "repetition awareness beats the losing line")
    }

    // The depth-limit cap is respected (used by deep analysis, max 22).
    private static func depthCap() {
        print("[depth cap]")
        let result = Engine.search(Board(), timeLimit: 5.0, depthLimit: 2)
        check(result.best != nil, "capped search returns a move")
        check(result.depth <= 2, "iterative deepening stopped at the cap (depth \(result.depth))")
    }

    // Picking an opponent must NOT auto-start; only startGame() (from setup)
    // begins play. After a game ends, resignation/agreement decide the result.
    private static func startFlow() {
        print("[start flow]")
        let g = GameState()
        g.thinkTime = 0.05            // keep any spawned search short

        g.setOpponent(.selfPlay)
        check(g.phase == .setup && !g.isPlaying, "picking self-play stays in setup, no auto-start")

        g.reset(); g.setOpponent(.off); g.startGame()
        check(g.phase == .playing && !g.isPlaying, "starting a two-human game does not autoplay")

        g.reset(); g.setOpponent(.selfPlay); g.startGame()
        check(g.phase == .playing && g.isPlaying, "startGame() begins self-play")
        g.pause()

        // Start Game does nothing unless we are in setup.
        g.reset()
        g.setOpponent(.computerBlack)   // human = Red
        g.startGame()
        g.startGame()                   // second call ignored (already playing)
        check(g.phase == .playing, "Start Game is a no-op once playing")

        // Resignation: the human (Red) concedes, Black wins, game finishes.
        g.resign()
        check(g.isGameOver && g.displayWinner == .black && g.phase == .finished,
              "resigning concedes to the opponent and finishes the game")

        // Agreed draw between two humans.
        let h = GameState()
        h.setOpponent(.off); h.startGame()
        h.offerDraw()
        check(h.drawAgreed && h.isGameOver && h.phase == .finished,
              "offering a draw in a two-human game agrees it")

        // Deep analysis is only available after entering analysis from finished.
        g.beginAnalysis()
        check(g.phase == .analysis, "Analyse game enters analysis")
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
