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
    @Published var winner: Side?            = nil
    @Published var log: [LogEntry]          = []
    @Published var highlightMoves: Set<Position>   = []
    @Published var highlightAttacks: Set<Position> = []

    init() { reset() }

    // MARK: Public API

    func reset() {
        pieces           = []
        selected         = nil
        turn             = .red
        winner           = nil
        log              = []
        highlightMoves   = []
        highlightAttacks = []
        buildStart()
        addLog("Game started — Red's turn.")
    }

    func tap(_ pos: Position) {
        guard winner == nil else { return }
        let tapped = piece(at: pos)
        if let sel = selected {
            if sel == pos {
                selected = nil
            } else if let t = tapped, t.side == turn {
                selected = pos
            } else if let p = piece(at: sel) {
                let (m, a) = validDestinations(for: p)
                if m.contains(pos) || a.contains(pos) {
                    move(from: sel, to: pos)
                }
                // invalid target — keep piece selected, do nothing
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
        var kingCaptured = false

        if let ci = pieces.firstIndex(where: { $0.pos == to }) {
            let captured = pieces[ci]
            entry += "  ×\(captured.type.fullName)"
            if captured.type == .king { kingCaptured = true }
            pieces.remove(at: ci)
        }
        if let ni = pieces.firstIndex(where: { $0.pos == from }) {
            pieces[ni].pos = to
        }

        addLog(entry)
        selected = nil

        if kingCaptured {
            winner = mover.side
            addLog("\(mover.side.rawValue) wins — king captured!")
        } else {
            turn = turn.other
            addLog("\(turn.rawValue)'s turn.")
        }
    }

    private func updateHighlights() {
        guard let sel = selected, let p = piece(at: sel) else {
            highlightMoves = []; highlightAttacks = []; return
        }
        let (m, a) = validDestinations(for: p)
        highlightMoves = m; highlightAttacks = a
    }

    // MARK: Movement rules

    func validDestinations(for p: Piece) -> (Set<Position>, Set<Position>) {
        switch p.type {
        case .skjolding:  return skjoldingDests(for: p)
        case .berserker:  return berserkerDests(for: p)
        case .spearman:   return spearmanDests(for: p)
        case .wolf:       return wolfDests(for: p)
        case .elf:        return elfDests(for: p)
        case .king:       return kingDests(for: p)
        case .dwarf:      return dwarfDests(for: p)
        case .hunter:     return hunterDests(for: p)
        default:          return slidingDests(for: p)
        }
    }

    // Skjolding: 2 forward (if 1-forward clear), diagonal forward ×2, 1 backward.
    // Shieldwall: diagonal is blocked when both adjacent orthogonal squares are occupied (any piece).
    private func skjoldingDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        let fwd = p.side == .red ? 1 : -1
        let c = p.pos.col, r = p.pos.row
        var moves = Set<Position>(), attacks = Set<Position>()

        func add(_ col: Int, _ row: Int) {
            guard Position.valid(col: col, row: row) else { return }
            let dest = Position(col: col, row: row)
            if let hit = piece(at: dest) {
                if hit.side != p.side { attacks.insert(dest) }
            } else {
                moves.insert(dest)
            }
        }

        func isOccupied(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            return piece(at: Position(col: col, row: row)) != nil
        }

        // 2 forward — only if the intervening square is empty
        if piece(at: Position(col: c, row: r + fwd)) == nil {
            add(c, r + 2 * fwd)
        }

        // diagonal forward — shieldwall blocks when BOTH adjacent orthogonals are occupied (any piece)
        for dc in [-1, 1] {
            if isOccupied(c, r + fwd) && isOccupied(c + dc, r) { continue }
            add(c + dc, r + fwd)
        }

        // 1 backward
        add(c, r - fwd)

        return (moves, attacks)
    }

    // Berserker: 3 forward lanes (col-1, col, col+1) each sliding up to 3 steps,
    // plus 1 step directly sideways. No backward movement.
    private func berserkerDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        let fwd = p.side == .red ? 1 : -1
        let c = p.pos.col, r = p.pos.row
        var moves = Set<Position>(), attacks = Set<Position>()

        // Returns true if passable (empty), false if blocked.
        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { attacks.insert(pos) }
                return false
            }
            moves.insert(pos)
            return true
        }

        func occupied(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            return piece(at: Position(col: col, row: row)) != nil
        }

        // Center lane: straight forward up to 3.
        for step in 1...3 { guard add(c, r + step * fwd) else { break } }

        // Side lanes: diagonal entry blocked by shieldwall (any two adjacent pieces).
        for dc in [-1, 1] {
            if occupied(c, r + fwd) && occupied(c + dc, r) { continue }
            for step in 1...3 { guard add(c + dc, r + step * fwd) else { break } }
        }

        // Direct sideways 1 step.
        for dc in [-1, 1] { _ = add(c + dc, r) }

        return (moves, attacks)
    }

    // Spearman: slides straight forward up to 4, plus 1 step sideways each direction.
    // No diagonals, no backward movement.
    private func spearmanDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        let fwd = p.side == .red ? 1 : -1
        let c = p.pos.col, r = p.pos.row
        var moves = Set<Position>(), attacks = Set<Position>()

        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { attacks.insert(pos) }
                return false
            }
            moves.insert(pos)
            return true
        }

        // Forward: slide up to 4 steps.
        for step in 1...4 { guard add(c, r + step * fwd) else { break } }

        // Sideways: 1 step each direction.
        for dc in [-1, 1] { _ = add(c + dc, r) }

        return (moves, attacks)
    }

    // Wolf: slides orthogonally up to 3 steps in any direction.
    private func wolfDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        var moves = Set<Position>(), attacks = Set<Position>()
        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0)] {
            var col = p.pos.col + dc, row = p.pos.row + dr
            for _ in 1...3 {
                guard Position.valid(col: col, row: row) else { break }
                let pos = Position(col: col, row: row)
                if let hit = piece(at: pos) {
                    if hit.side != p.side { attacks.insert(pos) }
                    break
                }
                moves.insert(pos)
                col += dc; row += dr
            }
        }
        return (moves, attacks)
    }

    // Elf: 1 step orthogonally in any direction (king-like), plus diagonal slide up to 4 steps.
    private func elfDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        var moves = Set<Position>(), attacks = Set<Position>()

        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { attacks.insert(pos) }
                return false
            }
            moves.insert(pos)
            return true
        }

        // Orthogonal: 1 step each direction.
        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0)] {
            _ = add(p.pos.col + dc, p.pos.row + dr)
        }

        // Diagonal: slide up to 4 steps each direction.
        for (dc, dr) in [(1,1),(1,-1),(-1,1),(-1,-1)] {
            var col = p.pos.col + dc, row = p.pos.row + dr
            for _ in 1...4 {
                guard add(col, row) else { break }
                col += dc; row += dr
            }
        }

        return (moves, attacks)
    }

    // King: 1 step in any of 8 directions.
    private func kingDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        var moves = Set<Position>(), attacks = Set<Position>()
        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0),(1,1),(1,-1),(-1,1),(-1,-1)] {
            let col = p.pos.col + dc, row = p.pos.row + dr
            guard Position.valid(col: col, row: row) else { continue }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { attacks.insert(pos) }
            } else {
                moves.insert(pos)
            }
        }
        return (moves, attacks)
    }

    // Dwarf: slides orthogonally up to 2, slides diagonally up to 2, plus knight-shape squares
    // (no jumping — a knight move is blocked if the square in the longer axis is occupied).
    private func dwarfDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        let c = p.pos.col, r = p.pos.row
        var moves = Set<Position>(), attacks = Set<Position>()

        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { attacks.insert(pos) }
                return false
            }
            moves.insert(pos)
            return true
        }

        func occupied(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            return piece(at: Position(col: col, row: row)) != nil
        }

        // Orthogonal slide up to 2.
        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0)] {
            for step in 1...2 { guard add(c + dc*step, r + dr*step) else { break } }
        }

        // Diagonal slide up to 2.
        for (dc, dr) in [(1,1),(1,-1),(-1,1),(-1,-1)] {
            for step in 1...2 { guard add(c + dc*step, r + dr*step) else { break } }
        }

        // Knight-shape moves — no jumping: blocked by a piece in the longer-axis direction.
        for (dc, dr) in [(2,1),(2,-1),(-2,1),(-2,-1),(1,2),(1,-2),(-1,2),(-1,-2)] {
            let transitCol = c + (abs(dc) > abs(dr) ? dc/2 : 0)
            let transitRow = r + (abs(dr) > abs(dc) ? dr/2 : 0)
            if occupied(transitCol, transitRow) { continue }
            _ = add(c + dc, r + dr)
        }

        return (moves, attacks)
    }

    // Hunter: 1 step diagonally in any direction, plus knight-shape squares (no jumping).
    private func hunterDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        let c = p.pos.col, r = p.pos.row
        var moves = Set<Position>(), attacks = Set<Position>()

        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { attacks.insert(pos) }
                return false
            }
            moves.insert(pos)
            return true
        }

        func occupied(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            return piece(at: Position(col: col, row: row)) != nil
        }

        // 1 step diagonally.
        for (dc, dr) in [(1,1),(1,-1),(-1,1),(-1,-1)] { _ = add(c + dc, r + dr) }

        // Knight-shape moves — no jumping: blocked by piece in the longer-axis direction.
        for (dc, dr) in [(2,1),(2,-1),(-2,1),(-2,-1),(1,2),(1,-2),(-1,2),(-1,-2)] {
            let transitCol = c + (abs(dc) > abs(dr) ? dc/2 : 0)
            let transitRow = r + (abs(dr) > abs(dc) ? dr/2 : 0)
            if occupied(transitCol, transitRow) { continue }
            _ = add(c + dc, r + dr)
        }

        return (moves, attacks)
    }

    // Fallback: unlimited straight-line movement in all 8 directions (no per-piece rule yet).
    private func slidingDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        var moves = Set<Position>(), attacks = Set<Position>()
        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0),(1,1),(1,-1),(-1,1),(-1,-1)] {
            var col = p.pos.col + dc, row = p.pos.row + dr
            while Position.valid(col: col, row: row) {
                let pos = Position(col: col, row: row)
                if let blocker = piece(at: pos) {
                    if blocker.side != p.side { attacks.insert(pos) }
                    break
                }
                moves.insert(pos)
                col += dc; row += dr
            }
        }
        return (moves, attacks)
    }

    // MARK: File-based command interface (for AI testing)
    // Write commands to /tmp/drott_cmd.txt:  "tap F6"  or  "reset"

    func startCommandListener() {
        let path = "/tmp/drott_cmd.txt"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 0.3)
                guard let self,
                      let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cmd.isEmpty else { continue }
                try? FileManager.default.removeItem(atPath: path)
                DispatchQueue.main.async { self.processCommand(cmd) }
            }
        }
    }

    private func processCommand(_ cmd: String) {
        let parts = cmd.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        switch verb {
        case "tap":
            guard let posStr = parts.dropFirst().first, posStr.count == 2,
                  let colChar = posStr.first?.uppercased().first,
                  let colAscii = colChar.asciiValue,
                  colAscii >= 65, colAscii <= 75,
                  let rowNum = Int(posStr.dropFirst()),
                  (1...11).contains(rowNum) else { return }
            tap(Position(col: Int(colAscii) - 65, row: rowNum - 1))
        case "reset":
            reset()
        default:
            break
        }
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

        // ── Black (point-symmetric: col → 10-col, row → 10-row) ─────────
        // Rank 11 — same formation as Red rank 1 from Black's own perspective
        place(.skjolding, .black, col: 8, row: 10)  // I11  ↔ C1
        place(.wolf,      .black, col: 7, row: 10)  // H11  ↔ D1
        place(.elf,       .black, col: 6, row: 10)  // G11  ↔ E1
        place(.king,      .black, col: 5, row: 10)  // F11  ↔ F1
        place(.dwarf,     .black, col: 4, row: 10)  // E11  ↔ G1
        place(.hunter,    .black, col: 3, row: 10)  // D11  ↔ H1
        place(.skjolding, .black, col: 2, row: 10)  // C11  ↔ I1
        // Rank 10
        place(.skjolding, .black, col: 7, row: 9)   // H10  ↔ D2
        place(.berserker, .black, col: 6, row: 9)   // G10  ↔ E2
        place(.spearman,  .black, col: 5, row: 9)   // F10  ↔ F2
        place(.bowman,    .black, col: 4, row: 9)   // E10  ↔ G2
        place(.skjolding, .black, col: 3, row: 9)   // D10  ↔ H2
        // Rank 9
        place(.skjolding, .black, col: 6, row: 8)   // G9   ↔ E3
        place(.skjolding, .black, col: 5, row: 8)   // F9   ↔ F3
        place(.skjolding, .black, col: 4, row: 8)   // E9   ↔ G3
    }
}
