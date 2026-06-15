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
        dwarfKnightLineOfSight()
        swordShieldwall()
        spearmanRangeTwo()
        berserkerLineOfSight()
        dwarfDiagonalTargetPinch()
        attackMapControl()
        sampleBerserkerProbe()
        freeCapture()
        herringboneTrades()
        developmentPreferences()
        hangingProbe()
        saveLoadRoundTrip()
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

    // Static Exchange Evaluation and the "don't drop pieces" behaviour it buys.
    private static func herringboneTrades() {
        print("[herringbone trades]")
        let d4 = Position(col: 3, row: 3)
        let d5 = Position(col: 3, row: 4)
        let e6 = Position(col: 4, row: 5)

        // Winning capture: a Dwarf takes an undefended pawn → SEE = +pawn.
        var win = Board.empty()
        win.put(.king, .red, Position(col: 0, row: 0))
        win.put(.king, .black, Position(col: 8, row: 8))
        win.put(.dwarf, .red, d4)
        win.put(.skjolding, .black, d5)          // undefended
        win.sideToMove = .red
        let seeWin = Engine.staticExchangeEval(win, Move(from: d4, to: d5, isCapture: true))
        check(seeWin == Engine.baseValue(.skjolding),
              "SEE values a free pawn capture at +\(Engine.baseValue(.skjolding)) (got \(seeWin))")

        // Losing capture: the same pawn is now defended by another pawn, so the
        // Dwarf (500) is lost for a pawn (100) → SEE = 100 - 500 = -400.
        var lose = win
        lose.put(.skjolding, .black, e6)         // defends D5 (diagonal forward for Black)
        let seeLose = Engine.staticExchangeEval(lose, Move(from: d4, to: d5, isCapture: true))
        check(seeLose == Engine.baseValue(.skjolding) - Engine.baseValue(.dwarf),
              "SEE values a Dwarf-for-pawn trade at -400 (got \(seeLose))")

        // And the engine must not actually play that losing capture when a safe
        // move is available.
        let best = Engine.bestMove(for: lose, timeLimit: 0.4)
        check(best != Move(from: d4, to: d5, isCapture: true),
              "engine declines the losing Dwarf-for-pawn trade (got \(best.map { lose.notation(for: $0) } ?? "nil"))")
    }

    // The engine must not move a piece onto a square where the opponent wins it
    // for free, when a safe alternative exists.
    private static func hangingProbe() {
        print("[hanging probe]")

        // After `mv`, the opponent's best profit (SEE) for capturing the moved
        // piece on its destination square.
        func hangsAfter(_ board: Board, _ mv: Move) -> Int {
            let after = board.applying(mv)
            guard after.winner == nil else { return 0 }
            var worst = 0
            for cap in after.captureMoves() where cap.to == mv.to {
                worst = max(worst, Engine.staticExchangeEval(after, cap))
            }
            return worst
        }

        func probe(_ name: String, _ b: Board, budget: Double = 2.0) {
            let best = Engine.bestMove(for: b, timeLimit: budget)
            let hung = best.map { hangsAfter(b, $0) } ?? 0
            let note = best.map { b.notation(for: $0) } ?? "nil"
            check(hung <= 0, "\(name): engine plays \(note) (hang=\(hung))")
        }

        // (1) A pawn that could advance onto a file raked by a Black bowman.
        var p1 = Board.empty()
        p1.put(.king, .red, Position(col: 0, row: 0))
        p1.put(.king, .black, Position(col: 8, row: 8))
        p1.put(.skjolding, .red, Position(col: 4, row: 1))   // E2
        p1.put(.bowman, .black, Position(col: 4, row: 6))    // E7 rakes E6..E3
        p1.sideToMove = .red
        probe("pawn vs raking bowman", p1)

        // (2) A dwarf that could step onto a square a Black pawn guards.
        var p2 = Board.empty()
        p2.put(.king, .red, Position(col: 0, row: 0))
        p2.put(.king, .black, Position(col: 8, row: 8))
        p2.put(.dwarf, .red, Position(col: 4, row: 2))       // E3
        p2.put(.skjolding, .black, Position(col: 3, row: 5)) // D6 guards E5 (and C5)
        p2.sideToMove = .red
        probe("dwarf vs pawn-guarded square", p2)

        // The variety pick chooses only among near-best moves and never hands the
        // opponent a free piece: sweeping the whole candidate pool, no pick hangs.
        var p3 = Board.empty()
        p3.put(.king, .red, Position(col: 0, row: 0))
        p3.put(.king, .black, Position(col: 8, row: 8))
        p3.put(.dwarf, .red, Position(col: 4, row: 2))
        p3.put(.skjolding, .black, Position(col: 3, row: 5))
        p3.sideToMove = .red
        let r = Engine.search(p3, timeLimit: 0.5)
        var maxHang = 0
        for f in stride(from: 0.0, to: 1.0, by: 0.05) {
            let picked = Engine.pickMove(from: r, on: p3, allowVariety: true, rng: { f })
            maxHang = max(maxHang, picked.map { hangsAfter(p3, $0) } ?? 0)
        }
        check(maxHang <= 0, "no variety pick across the pool hangs the moved piece (max=\(maxHang))")
    }

    // Diagnostic: reproduce Emil's medium game up to Red's move 23 and report
    // the Red Berserker's legal moves (expected to include E4).
    private static func sampleBerserkerProbe() {
        print("[berserker probe]")
        let text = """
        1. G2-G4   E7-D6
        2. Hu G1-H2   F7-E6
        3. Ax F1-H3   Sp E8-E7
        4. F3-F5   D6-C5
        5. F5xE6   D7-C6
        6. C2-C4   C6-C7
        7. G4-F5   C5-B4
        8. B1-B3   G8-G6
        9. F5-F7   C8-B7
        10. Ax H3-G5   B4-A3
        11. D3-D5   Bw D8-C8
        12. Bk D2-D4   Bk F8-G7
        13. Hu H2-G4   Bw C8-B8
        14. Wo C1-C2   C7-C5
        15. Wo C2-A2   Bw B8-C8
        16. Wo A2xA3   H9-I8
        17. Wo A3-A5   Sw F9-H7
        18. E3-F4   Ax D9-F8
        19. Wo A5-A7   Ax F8-H9
        20. Hu G4-I5   Sw H7-H8
        21. Wo A7-A9   K E9-F8
        22. Wo A9xB9   Ax H9-I9
        """
        let squares = GameState.parseSquares(text)        // 44 plies = 88 squares
        var b = Board()
        var ply = 0
        var i = 0
        while i + 1 < squares.count {
            let from = squares[i], to = squares[i + 1]; i += 2
            guard b.legalMoves().contains(where: { $0.from == from && $0.to == to }) else {
                check(false, "replay ply \(ply + 1) \(from)-\(to) is legal")
                return
            }
            b = b.applying(Move(from: from, to: to, isCapture: b.piece(at: to) != nil))
            ply += 1
        }
        check(b.sideToMove == .red, "after 44 plies it is Red to move (got \(b.sideToMove))")

        let e4 = Position(col: 4, row: 3)
        // Locate the Red berserker.
        var berserker: Piece?
        for sq in b.squares where sq?.type == .berserker && sq?.side == .red { berserker = sq }
        check(berserker != nil, "found the Red berserker (at \(berserker?.pos.description ?? "nil"))")
        if let bk = berserker {
            let (m, a) = b.validDestinations(for: bk)
            let onE4 = b.piece(at: e4).map { "\($0.side.rawValue) \($0.type.symbol)" } ?? "empty"
            print("    berserker at \(bk.pos), E4 is \(onE4), moves=\(m.map { $0.description }.sorted()) attacks=\(a.map { $0.description }.sorted())")
            check(m.contains(e4) || a.contains(e4), "Red berserker can move to E4")
        }
    }

    // The Sword (elf) slides diagonally but cannot slip between two pieces that
    // stand orthogonally on either side of a step (the shieldwall).
    private static func swordShieldwall() {
        print("[sword shieldwall]")
        let d4 = Position(col: 3, row: 3)
        let e5 = Position(col: 4, row: 4)
        let f6 = Position(col: 5, row: 5)

        // Both flanks of the D4→E5 step occupied → the NE diagonal is sealed.
        var sealed = Board.empty()
        sealed.put(.king, .red, Position(col: 0, row: 0))
        sealed.put(.king, .black, Position(col: 8, row: 8))
        sealed.put(.elf, .red, d4)
        sealed.put(.skjolding, .red, Position(col: 4, row: 3))    // E4
        sealed.put(.skjolding, .black, Position(col: 3, row: 4))  // D5
        let s1 = sealed.piece(at: d4)!
        let (m1, a1) = sealed.validDestinations(for: s1)
        check(!m1.contains(e5) && !a1.contains(e5) && !m1.contains(f6),
              "Sword cannot slip NE through a shieldwall (E4+D5 occupied)")

        // Only one flank occupied → the Sword slides through normally.
        var open = Board.empty()
        open.put(.king, .red, Position(col: 0, row: 0))
        open.put(.king, .black, Position(col: 8, row: 8))
        open.put(.elf, .red, d4)
        open.put(.skjolding, .red, Position(col: 4, row: 3))      // E4 only
        let s2 = open.piece(at: d4)!
        let (m2, _) = open.validDestinations(for: s2)
        check(m2.contains(e5) && m2.contains(f6),
              "Sword slides NE when only one flank is occupied")
    }

    // Spearman range-2 lateral moves must respect the secondary shieldwall: two
    // pieces flanking the step from the range-1 square to the range-2 square
    // should block passage, just as they would block any diagonal step.
    private static func spearmanRangeTwo() {
        print("[spearman range-2 shieldwall]")
        // Red Spearman at D4. Left diagonal (C5) is clear so leftClear=true.
        // Pieces at C6 and B5 form a shieldwall on the C5→B6 step.
        // The range-2 left destination B6 must be blocked.
        let d4  = Position(col: 3, row: 3)   // spearman
        let c5  = Position(col: 2, row: 4)   // range-1 left (must be empty)
        let b6  = Position(col: 1, row: 5)   // range-2 left target (should be blocked)
        let c6  = Position(col: 2, row: 5)   // secondary shieldwall piece (forward of C5)
        let b5  = Position(col: 1, row: 4)   // secondary shieldwall piece (left of C5)

        var blocked = Board.empty()
        blocked.put(.king, .red,   Position(col: 0, row: 0))
        blocked.put(.king, .black, Position(col: 8, row: 8))
        blocked.put(.spearman, .red, d4)
        blocked.put(.skjolding, .black, c6)   // secondary shieldwall
        blocked.put(.skjolding, .black, b5)   // secondary shieldwall
        let sp1 = blocked.piece(at: d4)!
        let (m1, _) = blocked.validDestinations(for: sp1)
        check( m1.contains(c5), "spearman can reach C5 (range-1 left, shieldwall not yet)")
        check(!m1.contains(b6), "spearman blocked at B6 by secondary shieldwall (C6+B5)")

        // Removing one shieldwall piece opens the path.
        var open = blocked
        open.squares[open.index(b5)] = nil
        let sp2 = open.piece(at: d4)!
        let (m2, _) = open.validDestinations(for: sp2)
        check(m2.contains(b6), "spearman reaches B6 when only one shieldwall piece present")

        // Symmetric test for range-2 right: E5 clear, pieces at E6+F5 block F6.
        let e5 = Position(col: 4, row: 4)
        let f6 = Position(col: 5, row: 5)
        let e6 = Position(col: 4, row: 5)
        let f5 = Position(col: 5, row: 4)

        var blockedR = Board.empty()
        blockedR.put(.king, .red,   Position(col: 0, row: 0))
        blockedR.put(.king, .black, Position(col: 8, row: 8))
        blockedR.put(.spearman, .red, d4)
        blockedR.put(.skjolding, .black, e6)
        blockedR.put(.skjolding, .black, f5)
        let sp3 = blockedR.piece(at: d4)!
        let (m3, _) = blockedR.validDestinations(for: sp3)
        check( m3.contains(e5), "spearman can reach E5 (range-1 right)")
        check(!m3.contains(f6), "spearman blocked at F6 by secondary shieldwall (E6+F5)")
    }

    // The berserker's forward-diagonal squares are leaps governed by line-of-sight:
    // a square two forward and one to the side is reachable even with the square
    // directly between occupied, as long as a straight line can thread to it — but
    // never by squeezing between two diagonally-adjacent pieces.
    private static func berserkerLineOfSight() {
        print("[berserker line-of-sight]")
        let d2 = Position(col: 3, row: 1)
        let e3 = Position(col: 4, row: 2)   // diagonal step (one fwd, one side)
        let e4 = Position(col: 4, row: 3)   // two fwd, one side  (the reported move)
        let e5 = Position(col: 4, row: 4)   // three fwd, one side
        let d3 = Position(col: 3, row: 2)
        let d4 = Position(col: 3, row: 3)

        // E3 occupied by a friendly piece, the D-file clear: the berserker threads
        // up the D-file and across to E4 / E5 — it leaps the single blocker.
        var leap = Board.empty()
        leap.put(.king, .red,   Position(col: 0, row: 0))
        leap.put(.king, .black, Position(col: 8, row: 8))
        leap.put(.berserker, .red, d2)
        leap.put(.skjolding, .red, e3)          // the square two-forward path would slide through
        let b1 = leap.piece(at: d2)!
        let (m1, _) = leap.validDestinations(for: b1)
        check(m1.contains(e4), "berserker reaches E4 (2 fwd, 1 side) past a single blocker on E3")
        check(m1.contains(e5), "berserker reaches E5 (3 fwd, 1 side) past a single blocker on E3")
        check(!m1.contains(e3), "berserker cannot land on the friendly piece at E3")

        // Now pinch the E4 leap between two diagonally-adjacent pieces: E3 and D4.
        // The line from D2 to E4 must squeeze through their shared corner → blocked.
        var pinch = Board.empty()
        pinch.put(.king, .red,   Position(col: 0, row: 0))
        pinch.put(.king, .black, Position(col: 8, row: 8))
        pinch.put(.berserker, .red, d2)
        pinch.put(.skjolding, .red, e3)
        pinch.put(.skjolding, .red, d4)
        let b2 = pinch.piece(at: d2)!
        let (m2, _) = pinch.validDestinations(for: b2)
        check(!m2.contains(e4), "berserker blocked from E4 when E3+D4 pinch the corner diagonally")

        // The straight-ahead column stays a true slide — a piece on D3 blocks D4.
        var slide = Board.empty()
        slide.put(.king, .red,   Position(col: 0, row: 0))
        slide.put(.king, .black, Position(col: 8, row: 8))
        slide.put(.berserker, .red, d2)
        slide.put(.skjolding, .red, d3)
        let b3 = slide.piece(at: d2)!
        let (m3, _) = slide.validDestinations(for: b3)
        check(!m3.contains(d4), "berserker straight-ahead is a slide — D3 blocks D4 (no leaping)")
    }

    // The dwarf's diagonal-2 leap is blocked by a pair of diagonally-adjacent
    // pieces pinching the TARGET corner, not only the origin corner / midpoint.
    private static func dwarfDiagonalTargetPinch() {
        print("[dwarf diagonal target pinch]")
        let b2 = Position(col: 1, row: 1)
        let d4 = Position(col: 3, row: 3)   // target (2 diagonal steps NE)
        let c3 = Position(col: 2, row: 2)   // midpoint on the line (kept clear)
        let c4 = Position(col: 2, row: 3)   // target-corner pinch
        let d3 = Position(col: 3, row: 2)   // target-corner pinch

        var pinch = Board.empty()
        pinch.put(.king, .red,   Position(col: 0, row: 0))
        pinch.put(.king, .black, Position(col: 8, row: 8))
        pinch.put(.dwarf, .red, b2)
        pinch.put(.skjolding, .black, c4)
        pinch.put(.skjolding, .black, d3)
        let dw = pinch.piece(at: b2)!
        let (m1, _) = pinch.validDestinations(for: dw)
        check(pinch.piece(at: c3) == nil, "midpoint C3 is clear in the dwarf pinch setup")
        check(!m1.contains(d4), "dwarf blocked from D4 when C4+D3 pinch the target corner")

        // Remove one pinch piece → the diagonal-2 leap opens up.
        var open = pinch
        open.squares[open.index(d3)] = nil
        let dw2 = open.piece(at: b2)!
        let (m2, _) = open.validDestinations(for: dw2)
        check(m2.contains(d4), "dwarf reaches D4 once the target-corner pinch is broken")
    }

    // Net square control: +1 per Red attacker, −1 per Black; both sides cancel.
    private static func attackMapControl() {
        print("[attack map]")
        func idx(_ c: Int, _ r: Int) -> Int { c + r * 9 }

        var b = Board.empty()
        b.put(.king, .red, Position(col: 0, row: 0))
        b.put(.king, .black, Position(col: 8, row: 8))
        b.put(.wolf, .red, Position(col: 4, row: 4))     // E5, slides orthogonally ≤3
        var net = b.attackControl()
        check(net[idx(4, 5)] == 1, "one red attacker tints +1 (got \(net[idx(4, 5)]))")   // E6

        // A Black wolf on E1 contests E2–E4 with the red wolf → net 0.
        b.put(.wolf, .black, Position(col: 4, row: 0))   // E1
        net = b.attackControl()
        check(net[idx(4, 2)] == 0, "a square attacked by both sides is neutral (got \(net[idx(4, 2)]))")

        // Two red attackers on one square stack to +2.
        var c = Board.empty()
        c.put(.king, .red, Position(col: 0, row: 0))
        c.put(.king, .black, Position(col: 8, row: 8))
        c.put(.wolf, .red, Position(col: 4, row: 4))     // E5 → attacks E4
        c.put(.wolf, .red, Position(col: 3, row: 3))     // D4 → attacks E4
        check(c.attackControl()[idx(4, 3)] == 2, "two red attackers stack to +2")
    }

    // A game can be exported to text and re-imported to the same position, and an
    // illegal move file is rejected without changing anything.
    private static func saveLoadRoundTrip() {
        print("[save / load]")
        // Build a real short game by always playing the first legal move.
        var b = Board()
        var text = "Drott 9×9\n"
        for _ in 0..<6 {
            guard let mv = b.legalMoves().first else { break }
            text += "\(mv.from)-\(mv.to)\n"
            b = b.applying(mv)
        }

        let g = GameState(); g.evalEnabled = false
        check(g.importGame(from: text), "import a generated game")
        check(g.record.count == 6, "imported the expected move count (\(g.record.count))")
        check(g.liveBoard == b, "imported final position matches the played game")

        // Export then re-import: the position must survive the round-trip.
        let g2 = GameState(); g2.evalEnabled = false
        check(g2.importGame(from: g.exportGame()), "re-import of exported text succeeds")
        check(g2.liveBoard == b, "round-trip reproduces the final position")

        // Lenient parsing: square pairs anywhere in the text are enough.
        check(GameState.parseSquares("note: E2-E4, then D8xD6!").count == 4,
              "parser extracts square pairs from prose")

        // A file with an illegal move is rejected and leaves the game untouched.
        let g3 = GameState(); g3.evalEnabled = false
        let before = g3.liveBoard
        check(!g3.importGame(from: "A1-A9"), "an illegal move file is rejected")
        check(g3.liveBoard == before, "rejected import does not mutate the game")
    }

    // Tier-specific development preferences in the static eval: minors hold the
    // center files, middle and major pieces head for the flanks, and middle
    // pieces are preferred to develop before major pieces.
    private static func developmentPreferences() {
        print("[development preferences]")
        // Red-perspective eval of a position with both kings plus one red test
        // piece; the kings are fixed, so eval differences isolate the piece term.
        func eval(_ type: PieceType, at pos: Position) -> Int {
            var b = Board.empty()
            b.put(.king, .red, Position(col: 0, row: 0))
            b.put(.king, .black, Position(col: 8, row: 8))
            b.put(type, .red, pos)
            return Engine.evaluate(b, for: .red)
        }
        let central = Position(col: 4, row: 3)   // central file, clear of forts/back rank
        let flank   = Position(col: 1, row: 3)   // flank file, same rank

        let minorCentral = eval(.spearman, at: central)
        let minorFlank   = eval(.spearman, at: flank)
        check(minorCentral > minorFlank,
              "minor piece prefers the central file (\(minorCentral) > \(minorFlank))")

        let middleFlank   = eval(.wolf, at: flank)
        let middleCentral = eval(.wolf, at: central)
        check(middleFlank > middleCentral,
              "middle piece prefers the flank file (\(middleFlank) > \(middleCentral))")

        // Major pieces prefer the flank files too — checked with the middle
        // pieces already developed, so the develop-middle-first term (which would
        // otherwise cancel a lone major's development) doesn't mask the file term.
        func evalMajor(at pos: Position) -> Int {
            var b = Board.empty()
            b.put(.king, .red, Position(col: 0, row: 0))
            b.put(.king, .black, Position(col: 8, row: 8))
            b.put(.wolf,   .red, Position(col: 0, row: 3))   // developed middle anchors
            b.put(.hunter, .red, Position(col: 8, row: 3))
            b.put(.dwarf,  .red, pos)
            return Engine.evaluate(b, for: .red)
        }
        let majorFlank   = evalMajor(at: flank)
        let majorCentral = evalMajor(at: central)
        check(majorFlank > majorCentral,
              "major piece prefers the flank file (\(majorFlank) > \(majorCentral))")

        // Develop middle before major: same two pieces, swapped between a
        // developed flank square and an undeveloped central back-rank square.
        func evalDev(middleAt: Position, majorAt: Position) -> Int {
            var b = Board.empty()
            b.put(.king, .red, Position(col: 0, row: 0))
            b.put(.king, .black, Position(col: 8, row: 8))
            b.put(.wolf,  .red, middleAt)
            b.put(.dwarf, .red, majorAt)
            return Engine.evaluate(b, for: .red)
        }
        let home  = Position(col: 4, row: 0)   // central, undeveloped
        let outDev = Position(col: 1, row: 1)  // flank, developed
        let middleFirst = evalDev(middleAt: outDev, majorAt: home)
        let majorFirst  = evalDev(middleAt: home,   majorAt: outDev)
        check(middleFirst > majorFirst,
              "developing the middle piece before the major scores higher (\(middleFirst) > \(majorFirst))")
    }

    // Knight-move blocking rule: a knight move threads to its target by one of two
    // routes, each pinched shut by a pair of diagonally adjacent pieces. The move is
    // blocked if any of three square-pairs is fully occupied: the two middle squares,
    // the origin-side corner pair, or the target-side corner pair.
    // At the start the Hunter at G1 is fully boxed in — every knight target is pinched:
    //   G1 → I2 (+2,+1): H1 and G2 pinch the origin corner → blocked.
    //   G1 → H3 (+1,+2): G2 and H1 pinch the origin corner → blocked.
    //   G1 → E2 (-2,+1): F1 and F2 are the two middle squares → blocked.
    //   G1 → F3 (-1,+2): G2 and F2 are the two middle squares → blocked.
    private static func hunterBoxedIn() {
        print("[hunter boxed in]")
        let b = Board()   // 9×9 default
        let hunter = b.piece(at: Position(col: 6, row: 0))!   // red Hunter at G1
        check(hunter.type == .hunter, "found the Hunter at G1")
        let (m, a) = b.validDestinations(for: hunter)
        let h3 = Position(col: 7, row: 2)
        let i2 = Position(col: 8, row: 1)
        let e2 = Position(col: 4, row: 1)
        let f3 = Position(col: 5, row: 2)
        check(!m.contains(h3) && !a.contains(h3), "Hunter blocked from H3 (origin corner pinched)")
        check(!m.contains(i2) && !a.contains(i2), "Hunter blocked from I2 (origin corner pinched)")
        check(!m.contains(e2) && !a.contains(e2), "Hunter blocked from E2 (two middle squares occupied)")
        check(!m.contains(f3) && !a.contains(f3), "Hunter blocked from F3 (two middle squares occupied)")
        check(m.isEmpty && a.isEmpty, "Hunter is fully boxed in at the start")
    }

    // A Dwarf on A4 reaching C3 (+2,-1): the long-axis square B4 is empty while the
    // diagonal square B3 is occupied. A line threads high through B4, so the move is
    // legal — a single occupied diagonal does NOT block on its own.
    private static func dwarfKnightLineOfSight() {
        print("[dwarf knight line of sight]")
        var b = Board.empty()
        b.put(.king, .red, Position(col: 8, row: 8))
        b.put(.king, .black, Position(col: 0, row: 8))
        b.put(.dwarf,     .red, Position(col: 0, row: 3))   // A4
        b.put(.skjolding, .red, Position(col: 1, row: 2))   // B3 (diagonal, occupied)
        b.sideToMove = .red                                  // B4 left empty
        let dwarf = b.piece(at: Position(col: 0, row: 3))!
        let (m, a) = b.validDestinations(for: dwarf)
        let c3 = Position(col: 2, row: 2)
        check(m.contains(c3) || a.contains(c3),
              "Dwarf reaches C3 with B4 empty though diagonal B3 is occupied")

        // Now fill B4 too: both middle squares occupied → the move must be blocked.
        b.put(.skjolding, .red, Position(col: 1, row: 3))   // B4
        let dwarf2 = b.piece(at: Position(col: 0, row: 3))!
        let (m2, a2) = b.validDestinations(for: dwarf2)
        check(!m2.contains(c3) && !a2.contains(c3),
              "Dwarf blocked from C3 once both B3 and B4 are occupied")

        // Corner-pinch (the "diagonal rule"): Dwarf F2 → H1 (+2,-1). The diagonal
        // square G1 is empty, but the origin-side corner is pinched shut by F1 and
        // G2 (diagonally adjacent, both occupied) → the move is blocked.
        var p = Board.empty()
        p.put(.king, .red, Position(col: 8, row: 8))
        p.put(.king, .black, Position(col: 0, row: 8))
        p.put(.dwarf,     .red, Position(col: 5, row: 1))   // F2
        p.put(.skjolding, .red, Position(col: 5, row: 0))   // F1 (short-axis orthogonal)
        p.put(.skjolding, .red, Position(col: 6, row: 1))   // G2 (long-axis orthogonal)
        p.sideToMove = .red                                  // G1 left empty
        let dwarf3 = p.piece(at: Position(col: 5, row: 1))!
        let (m3, a3) = p.validDestinations(for: dwarf3)
        let h1 = Position(col: 7, row: 0)
        check(!m3.contains(h1) && !a3.contains(h1),
              "Dwarf blocked from H1: F1 and G2 pinch the corner though G1 is empty")

        // Clearing F1 reopens the low route through the empty G1 → move legal again.
        p.squares[p.index(Position(col: 5, row: 0))] = nil   // remove F1
        let dwarf4 = p.piece(at: Position(col: 5, row: 1))!
        let (m4, a4) = p.validDestinations(for: dwarf4)
        check(m4.contains(h1) || a4.contains(h1),
              "Dwarf reaches H1 once F1 is cleared (corner no longer pinched)")
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
