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

    // Fort: the squares occupied by officers (non-Skjolding) at game start.
    static let redFortSquares: Set<Position> = [
        Position(col:3,row:0), Position(col:4,row:0), Position(col:5,row:0),
        Position(col:6,row:0), Position(col:7,row:0),
        Position(col:4,row:1), Position(col:5,row:1), Position(col:6,row:1)
    ]
    static let blackFortSquares: Set<Position> = [
        Position(col:3,row:10), Position(col:4,row:10), Position(col:5,row:10),
        Position(col:6,row:10), Position(col:7,row:10),
        Position(col:4,row:9),  Position(col:5,row:9),  Position(col:6,row:9)
    ]
    static func isRedFort(_ p: Position)        -> Bool { redFortSquares.contains(p) }
    static func isBlackFort(_ p: Position)      -> Bool { blackFortSquares.contains(p) }
    static func isFort(_ p: Position)           -> Bool { isRedFort(p) || isBlackFort(p) }
    static func isFort(_ p: Position, for s: Side) -> Bool { s == .red ? isRedFort(p) : isBlackFort(p) }

    // Castle zone: 3×3 around F6 plus 3-square orthogonal arms in each direction.
    static func isCastleZone(_ p: Position) -> Bool {
        let c = castle
        if abs(p.col - c.col) <= 1 && abs(p.row - c.row) <= 1 { return true }
        if p.col == c.col && abs(p.row - c.row) <= 3 { return true }
        if p.row == c.row && abs(p.col - c.col) <= 3 { return true }
        return false
    }

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
    let side: Side?   // nil = system message
}

// MARK: - Game State

class GameState: ObservableObject {
    @Published var pieces: [Piece]                 = []
    @Published var selected: Position?             = nil
    @Published var turn: Side                      = .red
    @Published var winner: Side?                   = nil
    @Published var castleWinPending: Side?         = nil
    @Published var log: [LogEntry]                 = []
    @Published var highlightMoves: Set<Position>   = []
    @Published var highlightAttacks: Set<Position> = []

    init() { reset() }

    // MARK: Public API

    func reset() {
        pieces            = []
        selected          = nil
        turn              = .red
        winner            = nil
        castleWinPending  = nil
        log               = []
        highlightMoves    = []
        highlightAttacks  = []
        buildStart()
        addLog("Game started.")
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

        // Build chess-style notation
        let sym = mover.type == .skjolding ? "" : mover.type.symbol
        var notation = sym.isEmpty ? "\(from)" : "\(sym) \(from)"
        var kingCaptured = false

        if let ci = pieces.firstIndex(where: { $0.pos == to }) {
            let captured = pieces[ci]
            if captured.type == .king { kingCaptured = true }
            notation += "×\(to)"
            pieces.remove(at: ci)
        } else {
            notation += "-\(to)"
        }
        if let ni = pieces.firstIndex(where: { $0.pos == from }) {
            pieces[ni].pos = to
        }

        addLog(notation, side: mover.side)
        selected = nil

        // Win condition 1: king captured
        if kingCaptured {
            winner = mover.side
            addLog("\(mover.side.rawValue) wins — king captured!")
            return
        }

        // Win condition 2 (pending): king lands on castle — wins on next turn
        if mover.type == .king && to == .castle {
            castleWinPending = mover.side
        } else if castleWinPending == mover.side,
                  !pieces.contains(where: { $0.type == .king && $0.side == mover.side && $0.pos == .castle }) {
            castleWinPending = nil  // king left the castle
        }

        // Win condition 3: fort occupation — checked after every move
        if let fortWinner = checkFortWin() {
            winner = fortWinner
            addLog("\(fortWinner.rawValue) wins — fort control!")
            return
        }

        turn = turn.other

        // Win condition 2 (resolve): does the new current player's king still hold the castle?
        if let pending = castleWinPending, pending == turn,
           pieces.contains(where: { $0.type == .king && $0.side == pending && $0.pos == .castle }) {
            winner = pending
            addLog("\(pending.rawValue) wins — king holds the castle!")
            return
        }
    }

    private func checkFortWin() -> Side? {
        for side in Side.allCases {
            let opp = side.other
            let sideInOppFort = pieces.contains { $0.side == side  && Position.isFort($0.pos, for: opp)  }
            let oppInOwnFort  = pieces.contains { $0.side == opp   && Position.isFort($0.pos, for: opp)  }
            if sideInOppFort && !oppInOwnFort { return side }
        }
        return nil
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
        case .bowman:     return bowmanDests(for: p)
        }
    }

    // Skjolding: 2 forward (if 1-forward clear), diagonal forward ×2, 1 backward.
    // Shieldwall: diagonal blocked when both adjacent orthogonals occupied (any piece).
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

        if piece(at: Position(col: c, row: r + fwd)) == nil { add(c, r + 2 * fwd) }

        for dc in [-1, 1] {
            if isOccupied(c, r + fwd) && isOccupied(c + dc, r) { continue }
            add(c + dc, r + fwd)
        }

        add(c, r - fwd)
        return (moves, attacks)
    }

    // Berserker: 3 forward lanes ×3 steps each, 1 sideways. Shieldwall at lane entry.
    private func berserkerDests(for p: Piece) -> (Set<Position>, Set<Position>) {
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
            moves.insert(pos); return true
        }

        func occupied(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            return piece(at: Position(col: col, row: row)) != nil
        }

        for step in 1...3 { guard add(c, r + step * fwd) else { break } }

        for dc in [-1, 1] {
            if occupied(c, r + fwd) && occupied(c + dc, r) { continue }
            for step in 1...3 { guard add(c + dc, r + step * fwd) else { break } }
        }

        for dc in [-1, 1] { _ = add(c + dc, r) }
        return (moves, attacks)
    }

    // Spearman: 3-wide at range 1 (shieldwall on diagonals), spread at range 2, 1 backward.
    // Moves: (-1,+1),(0,+1),(+1,+1) then (-2,+2),(0,+2),(+2,+2), plus (0,-1).
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
            moves.insert(pos); return true
        }

        func occupied(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            return piece(at: Position(col: col, row: row)) != nil
        }

        // Range 1: straight forward.
        let centerClear = add(c, r + fwd)

        // Range 1: diagonals with shieldwall.
        let leftClear: Bool
        if occupied(c, r + fwd) && occupied(c - 1, r) { leftClear = false }
        else { leftClear = add(c - 1, r + fwd) }

        let rightClear: Bool
        if occupied(c, r + fwd) && occupied(c + 1, r) { rightClear = false }
        else { rightClear = add(c + 1, r + fwd) }

        // Range 2: each lane extends one column further out.
        if centerClear { _ = add(c,     r + 2 * fwd) }
        if leftClear   { _ = add(c - 2, r + 2 * fwd) }
        if rightClear  { _ = add(c + 2, r + 2 * fwd) }

        // 1 step backward.
        _ = add(c, r - fwd)
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

    // Elf: 1 step orthogonally in any direction, plus diagonal slide up to 4 steps.
    private func elfDests(for p: Piece) -> (Set<Position>, Set<Position>) {
        var moves = Set<Position>(), attacks = Set<Position>()

        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { attacks.insert(pos) }
                return false
            }
            moves.insert(pos); return true
        }

        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0)] { _ = add(p.pos.col + dc, p.pos.row + dr) }

        for (dc, dr) in [(1,1),(1,-1),(-1,1),(-1,-1)] {
            var col = p.pos.col + dc, row = p.pos.row + dr
            for _ in 1...4 { guard add(col, row) else { break }; col += dc; row += dr }
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
            if let hit = piece(at: pos) { if hit.side != p.side { attacks.insert(pos) } }
            else { moves.insert(pos) }
        }
        return (moves, attacks)
    }

    // Dwarf: orthogonal slide ≤2, diagonal step 2 only (transit must be clear), knight-shape (no jump).
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
            moves.insert(pos); return true
        }

        func occupied(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            return piece(at: Position(col: col, row: row)) != nil
        }

        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0)] {
            for step in 1...2 { guard add(c + dc*step, r + dr*step) else { break } }
        }

        for (dc, dr) in [(1,1),(1,-1),(-1,1),(-1,-1)] {
            if occupied(c, r + dr) && occupied(c + dc, r) { continue }
            if occupied(c + dc, r + dr) { continue }
            _ = add(c + dc*2, r + dr*2)
        }

        for (dc, dr) in [(2,1),(2,-1),(-2,1),(-2,-1),(1,2),(1,-2),(-1,2),(-1,-2)] {
            let transitCol = c + (abs(dc) > abs(dr) ? dc/2 : 0)
            let transitRow = r + (abs(dr) > abs(dc) ? dr/2 : 0)
            if occupied(transitCol, transitRow) { continue }
            _ = add(c + dc, r + dr)
        }

        return (moves, attacks)
    }

    // Hunter: 1 step diagonal (shieldwall), knight-shape (both-wall blocking rule, no jump).
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
            moves.insert(pos); return true
        }

        func occupied(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row) else { return false }
            return piece(at: Position(col: col, row: row)) != nil
        }

        for (dc, dr) in [(1,1),(1,-1),(-1,1),(-1,-1)] {
            if occupied(c, r + dr) && occupied(c + dc, r) { continue }
            _ = add(c + dc, r + dr)
        }

        for (dc, dr) in [(2,1),(2,-1),(-2,1),(-2,-1),(1,2),(1,-2),(-1,2),(-1,-2)] {
            let wallBlocked: Bool
            if abs(dc) > abs(dr) {
                wallBlocked = occupied(c + dc/2, r) && occupied(c + dc/2, r + dr)
            } else {
                wallBlocked = occupied(c, r + dr/2) && occupied(c + dc, r + dr/2)
            }
            if wallBlocked { continue }
            _ = add(c + dc, r + dr)
        }

        return (moves, attacks)
    }

    // Bowman: slides straight forward up to 4, 1 step sideways each direction.
    private func bowmanDests(for p: Piece) -> (Set<Position>, Set<Position>) {
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
            moves.insert(pos); return true
        }

        for step in 1...4 { guard add(c, r + step * fwd) else { break } }
        for dc in [-1, 1] { _ = add(c + dc, r) }
        return (moves, attacks)
    }

    // Fallback: unlimited 8-direction slide (no per-piece rule yet).
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
                moves.insert(pos); col += dc; row += dr
            }
        }
        return (moves, attacks)
    }

    // MARK: File-based command interface
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

    private func addLog(_ text: String, side: Side? = nil) {
        log.append(LogEntry(text: text, side: side))
        if log.count > 200 { log.removeFirst() }
    }

    // MARK: Starting position
    //
    // Red (bottom):  rank 1: C1 V · D1 Wo · E1 El · F1 K · G1 Dw · H1 Hu · I1 V
    //                rank 2: D2 V · E2 Bk · F2 Sp · G2 Bw · H2 V
    //                rank 3: E3 V · F3 V · G3 V
    // Black (top): point-symmetric (col→10-col, row→10-row).

    private func place(_ type: PieceType, _ side: Side, col: Int, row: Int) {
        pieces.append(Piece(type: type, side: side, pos: Position(col: col, row: row)))
    }

    private func buildStart() {
        // Red
        place(.skjolding, .red, col: 2, row: 0)   // C1
        place(.wolf,      .red, col: 3, row: 0)   // D1
        place(.elf,       .red, col: 4, row: 0)   // E1
        place(.king,      .red, col: 5, row: 0)   // F1
        place(.dwarf,     .red, col: 6, row: 0)   // G1
        place(.hunter,    .red, col: 7, row: 0)   // H1
        place(.skjolding, .red, col: 8, row: 0)   // I1
        place(.skjolding, .red, col: 3, row: 1)   // D2
        place(.berserker, .red, col: 4, row: 1)   // E2
        place(.spearman,  .red, col: 5, row: 1)   // F2
        place(.bowman,    .red, col: 6, row: 1)   // G2
        place(.skjolding, .red, col: 7, row: 1)   // H2
        place(.skjolding, .red, col: 4, row: 2)   // E3
        place(.skjolding, .red, col: 5, row: 2)   // F3
        place(.skjolding, .red, col: 6, row: 2)   // G3

        // Black (point-symmetric)
        place(.skjolding, .black, col: 8, row: 10)  // I11
        place(.wolf,      .black, col: 7, row: 10)  // H11
        place(.elf,       .black, col: 6, row: 10)  // G11
        place(.king,      .black, col: 5, row: 10)  // F11
        place(.dwarf,     .black, col: 4, row: 10)  // E11
        place(.hunter,    .black, col: 3, row: 10)  // D11
        place(.skjolding, .black, col: 2, row: 10)  // C11
        place(.skjolding, .black, col: 7, row: 9)   // H10
        place(.berserker, .black, col: 6, row: 9)   // G10
        place(.spearman,  .black, col: 5, row: 9)   // F10
        place(.bowman,    .black, col: 4, row: 9)   // E10
        place(.skjolding, .black, col: 3, row: 9)   // D10
        place(.skjolding, .black, col: 6, row: 8)   // G9
        place(.skjolding, .black, col: 5, row: 8)   // F9
        place(.skjolding, .black, col: 4, row: 8)   // E9
    }
}
