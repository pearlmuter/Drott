import Foundation
import Combine

// MARK: - Position

struct Position: Equatable, Hashable, CustomStringConvertible {
    let col: Int  // 0–10  →  A–K
    let row: Int  // 0–10  →  rows 1–11 (0 = row 1 = bottom for Red)

    var colLabel: String { String(UnicodeScalar(65 + col)!) }
    var rowLabel: Int    { row + 1 }
    var description: String { "\(colLabel)\(rowLabel)" }

    static let castle = Position(col: 5, row: 5)  // F6

    // Fort: the 2-rank starting area at each end (cols C–I, ranks 1–2 / 10–11)
    static func isRedFort(_ p: Position)   -> Bool { (2...8).contains(p.col) && p.row <= 1  }
    static func isBlackFort(_ p: Position) -> Bool { (2...8).contains(p.col) && p.row >= 9  }
    static func isFort(_ p: Position)      -> Bool { isRedFort(p) || isBlackFort(p) }

    static func valid(col: Int, row: Int) -> Bool {
        (0..<11).contains(col) && (0..<11).contains(row)
    }
}

// MARK: - Pieces

enum Side: String, CaseIterable, Identifiable {
    case red = "Red", black = "Black"
    var id: String { rawValue }
    var other: Side { self == .red ? .black : .red }
}

enum PieceType: String, CaseIterable, Identifiable {
    case king, berserker, spearman, bowman, elf, wolf, dwarf, hunter, skjolding
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .king:      return "K"
        case .berserker: return "Bk"
        case .spearman:  return "Sp"
        case .bowman:    return "Bw"
        case .elf:       return "El"
        case .wolf:      return "Wo"
        case .dwarf:     return "Dw"
        case .hunter:    return "Hu"
        case .skjolding: return "V"
        }
    }
    var fullName: String { rawValue.capitalized }
}

struct Piece: Identifiable {
    let id = UUID()
    let type: PieceType
    let side: Side
    var pos: Position
}

// MARK: - Log

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Game State

class GameState: ObservableObject {
    @Published var pieces: [Piece]          = []
    @Published var selected: Position?      = nil
    @Published var turn: Side               = .red
    @Published var log: [LogEntry]          = []
    @Published var highlightMoves: Set<Position>   = []
    @Published var highlightAttacks: Set<Position> = []

    init() { reset() }

    // MARK: Public API

    func reset() {
        pieces         = []
        selected       = nil
        turn           = .red
        log            = []
        highlightMoves = []
        highlightAttacks = []
        buildStart()
        addLog("Game started — Red's turn.")
    }

    func tap(_ pos: Position) {
        let tapped = piece(at: pos)
        if let sel = selected {
            if sel == pos {
                selected = nil
            } else if let t = tapped, t.side == turn {
                selected = pos
            } else {
                move(from: sel, to: pos)
            }
        } else if let t = tapped, t.side == turn {
            selected = pos
        }
        updateHighlights()
    }

    func piece(at pos: Position) -> Piece? {
        pieces.first { $0.pos == pos }
    }

    // MARK: Private

    private func move(from: Position, to: Position) {
        guard let fi = pieces.firstIndex(where: { $0.pos == from }) else {
            selected = nil; return
        }
        let mover = pieces[fi]
        if let blocker = piece(at: to), blocker.side == mover.side {
            selected = nil; return
        }

        var entry = "\(mover.side.rawValue) \(mover.type.fullName)  \(from) → \(to)"

        if let ci = pieces.firstIndex(where: { $0.pos == to }) {
            entry += "  ×\(pieces[ci].type.fullName)"
            pieces.remove(at: ci)
        }
        if let ni = pieces.firstIndex(where: { $0.pos == from }) {
            pieces[ni].pos = to
        }

        addLog(entry)
        selected = nil
        turn = turn.other
        addLog("\(turn.rawValue)'s turn.")
    }

    // Straight-line reachability (all 8 directions, blocked by any piece).
    // Per-piece movement ranges are not yet enforced — to be added.
    private func updateHighlights() {
        guard let sel = selected, let p = piece(at: sel) else {
            highlightMoves   = []
            highlightAttacks = []
            return
        }
        var moves   = Set<Position>()
        var attacks = Set<Position>()

        let dirs = [(0,1),(0,-1),(1,0),(-1,0),(1,1),(1,-1),(-1,1),(-1,-1)]
        for (dc, dr) in dirs {
            var c = p.pos.col + dc
            var r = p.pos.row + dr
            while Position.valid(col: c, row: r) {
                let pos = Position(col: c, row: r)
                if let blocker = piece(at: pos) {
                    if blocker.side != p.side { attacks.insert(pos) }
                    break
                }
                moves.insert(pos)
                c += dc; r += dr
            }
        }
        highlightMoves   = moves
        highlightAttacks = attacks
    }

    private func addLog(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 200 { log.removeFirst() }
    }

    // MARK: Starting position
    //
    // Red (bottom):
    //   Rank 1 (row=0): V C1 · Wo D1 · El E1 · K F1 · Bk G1 · Hu H1 · V I1
    //   Rank 2 (row=1): V D2 · Bw E2 · Sp F2 · Dw G2 · V H2
    //   Rank 3 (row=2): V E3 · V F3 · V G3
    //
    // Black (top) is the vertical mirror.

    private func place(_ type: PieceType, _ side: Side, col: Int, row: Int) {
        pieces.append(Piece(type: type, side: side, pos: Position(col: col, row: row)))
    }

    private func buildStart() {
        // ── Red ───────────────────────────────────────────────────────────
        // Rank 1
        place(.skjolding, .red, col: 2, row: 0)   // C1
        place(.wolf,      .red, col: 3, row: 0)   // D1
        place(.elf,       .red, col: 4, row: 0)   // E1
        place(.king,      .red, col: 5, row: 0)   // F1
        place(.dwarf,     .red, col: 6, row: 0)   // G1
        place(.hunter,    .red, col: 7, row: 0)   // H1
        place(.skjolding, .red, col: 8, row: 0)   // I1
        // Rank 2
        place(.skjolding, .red, col: 3, row: 1)   // D2
        place(.berserker, .red, col: 4, row: 1)   // E2
        place(.spearman,  .red, col: 5, row: 1)   // F2
        place(.bowman,    .red, col: 6, row: 1)   // G2
        place(.skjolding, .red, col: 7, row: 1)   // H2
        // Rank 3
        place(.skjolding, .red, col: 4, row: 2)   // E3
        place(.skjolding, .red, col: 5, row: 2)   // F3
        place(.skjolding, .red, col: 6, row: 2)   // G3

        // ── Black (mirrored) ──────────────────────────────────────────────
        // Rank 11
        place(.skjolding, .black, col: 2, row: 10)  // C11
        place(.wolf,      .black, col: 3, row: 10)  // D11
        place(.elf,       .black, col: 4, row: 10)  // E11
        place(.king,      .black, col: 5, row: 10)  // F11
        place(.dwarf,     .black, col: 6, row: 10)  // G11
        place(.hunter,    .black, col: 7, row: 10)  // H11
        place(.skjolding, .black, col: 8, row: 10)  // I11
        // Rank 10
        place(.skjolding, .black, col: 3, row: 9)   // D10
        place(.berserker, .black, col: 4, row: 9)   // E10
        place(.spearman,  .black, col: 5, row: 9)   // F10
        place(.bowman,    .black, col: 6, row: 9)   // G10
        place(.skjolding, .black, col: 7, row: 9)   // H10
        // Rank 9
        place(.skjolding, .black, col: 4, row: 8)   // E9
        place(.skjolding, .black, col: 5, row: 8)   // F9
        place(.skjolding, .black, col: 6, row: 8)   // G9
    }
}
