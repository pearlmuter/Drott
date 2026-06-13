import Foundation
import Combine

// MARK: - Position

struct Position: Equatable, Hashable, CustomStringConvertible {
    let col: Int  // 0–10  →  A–K
    let row: Int  // 0–10  →  rows 1–11 (0 = row 1 = bottom for Red)

    var colLabel: String { String(UnicodeScalar(65 + col)!) }
    var rowLabel: Int    { row + 1 }
    var description: String { "\(colLabel)\(rowLabel)" }

    // Centre of the board
    static let castle = Position(col: 5, row: 5)  // F6

    // Fort: the 2-row × 5-col starting area at each end
    static func isRedFort(_ p: Position)   -> Bool { (3...7).contains(p.col) && p.row <= 1  }
    static func isBlackFort(_ p: Position) -> Bool { (3...7).contains(p.col) && p.row >= 9  }
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
    @Published var pieces: [Piece]    = []
    @Published var selected: Position? = nil
    @Published var turn: Side          = .red
    @Published var log: [LogEntry]     = []

    init() { reset() }

    // MARK: Public API

    func reset() {
        pieces   = []
        selected = nil
        turn     = .red
        log      = []
        buildStart()
        addLog("Game started — Red's turn.")
    }

    func tap(_ pos: Position) {
        let tapped = piece(at: pos)
        if let sel = selected {
            if sel == pos {
                selected = nil
            } else if let t = tapped, t.side == turn {
                selected = pos          // reselect another friendly piece
            } else {
                move(from: sel, to: pos)
            }
        } else if let t = tapped, t.side == turn {
            selected = pos
        }
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
        // Can't land on own piece
        if let blocker = piece(at: to), blocker.side == mover.side {
            selected = nil; return
        }

        var entry = "\(mover.side.rawValue) \(mover.type.fullName)  \(from) → \(to)"

        // Capture
        if let ci = pieces.firstIndex(where: { $0.pos == to }) {
            entry += "  ×\(pieces[ci].type.fullName)"
            pieces.remove(at: ci)
        }
        // Move (re-find after possible removal)
        if let ni = pieces.firstIndex(where: { $0.pos == from }) {
            pieces[ni].pos = to
        }

        addLog(entry)
        selected = nil
        turn = turn.other
        addLog("\(turn.rawValue)'s turn.")
    }

    private func addLog(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 200 { log.removeFirst() }
    }

    // MARK: Starting position
    //
    // Red (bottom):
    //   Row 1 (row=0): Berserker E1, Spearman F1, Bowman G1
    //   Row 2 (row=1): Wolf D2, Elf E2, King F2, Dwarf G2, Hunter H2
    //   Row 3 (row=2): Skjoldings B3–J3
    //
    // Black (top), mirrored vertically.

    private func place(_ type: PieceType, _ side: Side, col: Int, row: Int) {
        pieces.append(Piece(type: type, side: side, pos: Position(col: col, row: row)))
    }

    private func buildStart() {
        // Red
        place(.berserker, .red, col: 4, row: 0)
        place(.spearman,  .red, col: 5, row: 0)
        place(.bowman,    .red, col: 6, row: 0)

        place(.wolf,    .red, col: 3, row: 1)
        place(.elf,     .red, col: 4, row: 1)
        place(.king,    .red, col: 5, row: 1)
        place(.dwarf,   .red, col: 6, row: 1)
        place(.hunter,  .red, col: 7, row: 1)

        for c in 1...9 { place(.skjolding, .red,   col: c, row: 2) }

        // Black (mirrored)
        place(.berserker, .black, col: 4, row: 10)
        place(.spearman,  .black, col: 5, row: 10)
        place(.bowman,    .black, col: 6, row: 10)

        place(.wolf,    .black, col: 3, row: 9)
        place(.elf,     .black, col: 4, row: 9)
        place(.king,    .black, col: 5, row: 9)
        place(.dwarf,   .black, col: 6, row: 9)
        place(.hunter,  .black, col: 7, row: 9)

        for c in 1...9 { place(.skjolding, .black, col: c, row: 8) }
    }
}
