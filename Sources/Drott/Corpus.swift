import Foundation

// MARK: - Golden parity corpus
//
// `DROTT_DUMP_CORPUS=1 swift run` writes a JSON corpus of positions and exits.
// It is the contract the Python rules port (python/drott_rules.py) must satisfy
// 100% before any neural-net training begins — the gate against Swift/Python
// rule drift (see ALPHAZERO_PLAN.md §3.1).
//
// Each case is a LIVE position (winner == nil). For every legal move we record
// the resulting board's `repetitionKey`, `winner`, and `winReason`. Terminal
// positions are therefore validated as move-*results*, never as standalone
// cases — which is why the curated set includes positions one ply before a
// castle/fort survival win, so those win conditions appear in a move list.
//
// Output path: $DROTT_CORPUS_OUT or ./parity_corpus.json.

enum Corpus {

    // A tiny deterministic xorshift64 so the corpus is byte-stable across runs
    // (nice git diffs). Python never replays these games — it only validates the
    // dumped positions — so this RNG is Swift-only.
    private struct RNG {
        var s: UInt64
        mutating func next() -> UInt64 {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return s
        }
        mutating func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private static func sideStr(_ s: Side) -> String { s == .red ? "red" : "black" }

    private static func reasonStr(_ r: WinReason?) -> Any {
        switch r {
        case .kingCapture: return "kingCapture"
        case .castle:      return "castle"
        case .fort:        return "fort"
        case .none:        return NSNull()
        }
    }

    private static func piecesArray(_ b: Board) -> [[Any]] {
        var out: [[Any]] = []
        for sq in b.squares {
            guard let p = sq else { continue }
            out.append([p.pos.col, p.pos.row, p.type.rawValue, sideStr(p.side)])
        }
        return out
    }

    /// Encode one live position (winner must be nil) as a corpus case.
    private static func caseDict(_ id: String, _ b: Board) -> [String: Any] {
        var moves: [[String: Any]] = []
        for mv in b.legalMoves() {
            let r = b.applying(mv)
            moves.append([
                "f":   [mv.from.col, mv.from.row],
                "t":   [mv.to.col, mv.to.row],
                "cap": mv.isCapture,
                "k":   String(r.repetitionKey),
                "w":   r.winner.map { sideStr($0) as Any } ?? NSNull(),
                "wr":  reasonStr(r.winReason),
            ])
        }
        return [
            "id":     id,
            "side":   sideStr(b.sideToMove),
            "pieces": piecesArray(b),
            "key":    String(b.repetitionKey),
            "moves":  moves,
        ]
    }

    static func exportIfRequested() {
        guard ProcessInfo.processInfo.environment["DROTT_DUMP_CORPUS"] == "1" else { return }

        var cases: [[String: Any]] = []
        var seen = Set<UInt64>()          // dedup positions by repetitionKey

        // Add a live position once (skips terminals and duplicates).
        func add(_ id: String, _ b: Board) {
            guard b.winner == nil else { return }
            let k = b.repetitionKey
            guard !seen.contains(k) else { return }
            seen.insert(k)
            cases.append(caseDict(id, b))
        }

        // 1. Opening, both sides to move.
        do {
            var b = Board(); add("start.red", b)
            b.sideToMove = .black; add("start.black", b)
        }

        // 2. Single-piece sweep: every piece type, each side, on every square,
        //    with the two kings in opposite corners. Exercises move generation —
        //    including off-board probes — at every square, edge, and corner.
        let corners = [Position(col: 0, row: 0), Position(col: 8, row: 8)]
        for type in PieceType.allCases {
            for side in Side.allCases {
                for row in 0..<9 {
                    for col in 0..<9 {
                        let here = Position(col: col, row: row)
                        if corners.contains(here) { continue }   // keep both kings intact
                        var b = Board.empty()
                        b.put(.king, .red,   corners[0])
                        b.put(.king, .black, corners[1])
                        b.put(type, side, here)
                        b.sideToMove = side
                        add("sweep.\(type.rawValue).\(sideStr(side)).\(here)", b)
                    }
                }
            }
        }

        // 3. Seeded random self-play: dense, interacting positions with captures,
        //    blocks, and the occasional king capture. Dump every live position.
        var rng = RNG(s: 0x9E3779B97F4A7C15)
        let games = 80, plyCap = 160
        for g in 0..<games {
            var b = Board()
            for ply in 0..<plyCap {
                add("game\(g).ply\(ply)", b)
                let moves = b.legalMoves()
                if moves.isEmpty { break }
                let mv = moves[rng.pick(moves.count)]
                b = b.applying(mv)
                if b.winner != nil { break }     // result already validated via the parent case
            }
        }

        // 4. Curated edge cases — the highest-value tactical/win-timing positions,
        //    mirroring the Swift self-tests. These guarantee the corpus exercises
        //    shieldwalls, knight/leap pinches, and (crucially) the castle/fort
        //    survival wins, which appear here as move-results.
        for (id, b) in curatedCases() { add(id, b) }

        // Serialize.
        let root: [String: Any] = ["version": 1, "boardN": 9, "cases": cases]
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.sortedKeys]) else {
            FileHandle.standardError.write(Data("corpus serialization failed\n".utf8))
            exit(1)
        }
        let path = ProcessInfo.processInfo.environment["DROTT_CORPUS_OUT"] ?? "parity_corpus.json"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            let moveCount = cases.reduce(0) { $0 + (($1["moves"] as? [Any])?.count ?? 0) }
            print("wrote \(path): \(cases.count) positions, \(moveCount) transitions")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("corpus write failed: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: Curated tactical & win-timing positions

    private static func curatedCases() -> [(String, Board)] {
        var out: [(String, Board)] = []
        func P(_ c: Int, _ r: Int) -> Position { Position(col: c, row: r) }

        // --- king-capture available: Red wolf C1 can slide onto the Black king C3.
        do {
            var b = Board.empty()
            b.put(.king, .red, P(0, 0)); b.put(.king, .black, P(2, 2))
            b.put(.wolf, .red, P(2, 0))
            b.put(.skjolding, .red, P(7, 0)); b.put(.skjolding, .black, P(7, 8))
            b.sideToMove = .red
            out.append(("curated.kingCapture", b))
        }

        // --- castle survival: Red king already ON the castle, Black to move. Any
        //     harmless Black move leaves Red holding the castle → result castle win.
        do {
            var b = Board.empty()
            b.put(.king, .red, Position.castle(N: 9))   // E5
            b.put(.king, .black, P(8, 8))
            b.put(.skjolding, .black, P(0, 8))          // a harmless reply far away
            b.sideToMove = .black
            out.append(("curated.castleSurvive", b))
        }

        // --- fort survival vs denial: Red skjolding already IN Black's fort (D9),
        //     Black to move. One Black reply (king C9×D9) denies it; others let it
        //     survive → fort win. Both branches appear in the move list.
        do {
            var b = Board.empty()
            b.put(.king, .red, P(0, 0))
            b.put(.wolf, .red, P(3, 8))                 // D9, inside the black fort
            b.put(.king, .black, P(2, 8))               // C9, can capture D9
            b.put(.skjolding, .black, P(0, 6))          // A7, a harmless alternative
            b.sideToMove = .black
            out.append(("curated.fortSurviveOrDeny", b))
        }

        // --- sword (elf) shieldwall sealed: NE diagonal blocked by E4+D5.
        do {
            var b = Board.empty()
            b.put(.king, .red, P(0, 0)); b.put(.king, .black, P(8, 8))
            b.put(.elf, .red, P(3, 3))                  // D4
            b.put(.skjolding, .red, P(4, 3))            // E4
            b.put(.skjolding, .black, P(3, 4))          // D5
            b.sideToMove = .red
            out.append(("curated.swordShieldwall", b))
        }

        // --- berserker line-of-sight: single blocker E3 (leap past), and the
        //     E3+D4 diagonal pinch (blocked).
        do {
            var b = Board.empty()
            b.put(.king, .red, P(0, 0)); b.put(.king, .black, P(8, 8))
            b.put(.berserker, .red, P(3, 1))            // D2
            b.put(.skjolding, .red, P(4, 2))            // E3 single blocker
            b.sideToMove = .red
            out.append(("curated.berserkerLeap", b))

            b.put(.skjolding, .red, P(3, 3))            // add D4 → diagonal pinch
            out.append(("curated.berserkerPinch", b))
        }

        // --- spearman range-2 secondary shieldwall: C6+B5 block B6.
        do {
            var b = Board.empty()
            b.put(.king, .red, P(0, 0)); b.put(.king, .black, P(8, 8))
            b.put(.spearman, .red, P(3, 3))             // D4
            b.put(.skjolding, .black, P(2, 5))          // C6
            b.put(.skjolding, .black, P(1, 4))          // B5
            b.sideToMove = .red
            out.append(("curated.spearmanRange2", b))
        }

        // --- dwarf knight-shape & diagonal-2 pinches.
        do {
            var b = Board.empty()
            b.put(.king, .red, P(8, 8)); b.put(.king, .black, P(0, 8))
            b.put(.dwarf, .red, P(0, 3))                // A4
            b.put(.skjolding, .red, P(1, 2))            // B3 (diagonal occupied, B4 empty)
            b.sideToMove = .red
            out.append(("curated.dwarfKnightLOS", b))

            // dwarf diagonal-2 target-corner pinch: C4+D3 block D4 from B2.
            var d = Board.empty()
            d.put(.king, .red, P(0, 0)); d.put(.king, .black, P(8, 8))
            d.put(.dwarf, .red, P(1, 1))                // B2
            d.put(.skjolding, .black, P(2, 3))          // C4
            d.put(.skjolding, .black, P(3, 2))          // D3
            d.sideToMove = .red
            out.append(("curated.dwarfTargetPinch", d))
        }

        return out
    }
}
