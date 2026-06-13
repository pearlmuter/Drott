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

    /// Chebyshev (king-move) distance.
    func chebyshev(to o: Position) -> Int { max(abs(col - o.col), abs(row - o.row)) }
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

struct Piece: Identifiable, Equatable {
    let id = UUID()
    let type: PieceType
    let side: Side
    var pos: Position
}

// MARK: - Move

struct Move: Equatable {
    let from: Position
    let to: Position
    let isCapture: Bool
}

enum WinReason { case kingCapture, castle, fort }

// MARK: - Log

/// One played move, recorded for the move list and history navigation.
/// `record[i]` is the move that produced `history[i+1]`.
struct MoveRecord: Identifiable {
    let id = UUID()
    let notation: String
    let side: Side
    let reason: WinReason?   // set if this move ended the game
}

/// Who controls each side.
enum OpponentMode: Hashable {
    case off            // two humans
    case computerBlack  // computer plays Black
    case computerRed    // computer plays Red
    case selfPlay       // computer plays both
}

// MARK: - Board
//
// A pure value type holding the full game state. This is the single source of
// truth for the rules of Drott: movement generation, move application, and the
// three win conditions all live here, so the UI (GameState) and the AI (Engine)
// share identical logic.

struct Board {
    static let N = 11

    var squares: [Piece?]          // count 121, indexed col + row*N
    var sideToMove: Side
    var castleWinPending: Side?
    var winner: Side?
    var winReason: WinReason?

    init() {
        squares = Array(repeating: nil, count: Board.N * Board.N)
        sideToMove = .red
        castleWinPending = nil
        winner = nil
        winReason = nil
        setupStart()
    }

    // MARK: Access

    @inline(__always) func index(_ col: Int, _ row: Int) -> Int { col + row * Board.N }
    @inline(__always) func index(_ p: Position) -> Int { p.col + p.row * Board.N }

    /// Returns nil for off-board positions. The movement rules rely on this:
    /// they probe neighbouring squares (e.g. one rank ahead) without bounds
    /// checking first, so an off-board probe must be a safe miss, not a trap.
    func piece(at pos: Position) -> Piece? {
        guard Position.valid(col: pos.col, row: pos.row) else { return nil }
        return squares[index(pos)]
    }

    var pieces: [Piece] { squares.compactMap { $0 } }

    func kingPosition(of side: Side) -> Position? {
        for sq in squares where sq?.type == .king && sq?.side == side { return sq!.pos }
        return nil
    }

    // MARK: Move generation

    /// All pseudo-legal moves for the side to move. Drott has no "check"
    /// legality — leaving your king capturable is legal (just losing), so every
    /// generated move is playable.
    func legalMoves() -> [Move] {
        var result: [Move] = []
        result.reserveCapacity(64)
        for sq in squares {
            guard let p = sq, p.side == sideToMove else { continue }
            let (m, a) = validDestinations(for: p)
            for d in m { result.append(Move(from: p.pos, to: d, isCapture: false)) }
            for d in a { result.append(Move(from: p.pos, to: d, isCapture: true)) }
        }
        return result
    }

    func captureMoves() -> [Move] {
        var result: [Move] = []
        for sq in squares {
            guard let p = sq, p.side == sideToMove else { continue }
            let (_, a) = validDestinations(for: p)
            for d in a { result.append(Move(from: p.pos, to: d, isCapture: true)) }
        }
        return result
    }

    // MARK: Apply
    //
    // Returns the board after `move`. Mirrors the win-condition ordering exactly:
    // king-capture → castle-pending bookkeeping → fort control → switch turn →
    // resolve a pending castle hold. The side to move is ALWAYS switched at the
    // end (even on a terminal move) so the negamax sign convention stays valid.

    func applying(_ move: Move) -> Board {
        var b = self
        b.winReason = nil
        let fromIdx = index(move.from)
        let toIdx   = index(move.to)
        guard var mover = b.squares[fromIdx] else { return b }
        let moverSide = mover.side

        if let captured = b.squares[toIdx] {
            if captured.type == .king {
                b.winner = moverSide
                b.winReason = .kingCapture
            }
        }

        // Relocate the mover.
        mover.pos = move.to
        b.squares[toIdx] = mover
        b.squares[fromIdx] = nil

        if b.winner == nil {
            // Castle-pending bookkeeping.
            if mover.type == .king && move.to == .castle {
                b.castleWinPending = moverSide
            } else if b.castleWinPending == moverSide,
                      b.kingPosition(of: moverSide) != .castle {
                b.castleWinPending = nil
            }

            // Fort control.
            if let fw = b.checkFortWin() {
                b.winner = fw
                b.winReason = .fort
            }
        }

        // Always switch the side to move.
        b.sideToMove = moverSide.other

        // Resolve a pending castle hold: the holder wins once it becomes their
        // turn again with the king still on the castle.
        if b.winner == nil,
           let pending = b.castleWinPending,
           pending == b.sideToMove,
           b.kingPosition(of: pending) == .castle {
            b.winner = pending
            b.winReason = .castle
        }

        return b
    }

    func checkFortWin() -> Side? {
        for side in Side.allCases {
            let opp = side.other
            var sideInOppFort = false
            var oppInOwnFort = false
            for sq in squares {
                guard let p = sq else { continue }
                if p.side == side && Position.isFort(p.pos, for: opp) { sideInOppFort = true }
                if p.side == opp  && Position.isFort(p.pos, for: opp) { oppInOwnFort = true }
            }
            if sideInOppFort && !oppInOwnFort { return side }
        }
        return nil
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

        let centerClear = add(c, r + fwd)
        let leftClear: Bool
        if occupied(c, r + fwd) && occupied(c - 1, r) { leftClear = false }
        else { leftClear = add(c - 1, r + fwd) }
        let rightClear: Bool
        if occupied(c, r + fwd) && occupied(c + 1, r) { rightClear = false }
        else { rightClear = add(c + 1, r + fwd) }

        if centerClear { _ = add(c,     r + 2 * fwd) }
        if leftClear   { _ = add(c - 2, r + 2 * fwd) }
        if rightClear  { _ = add(c + 2, r + 2 * fwd) }

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

    // Dwarf: orthogonal slide ≤2, diagonal step 2 only (transit clear), knight-shape (no jump).
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

    // Hunter: 1 step diagonal (shieldwall), knight-shape (both-wall blocking, no jump).
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

    // MARK: Starting position
    //
    // Red (bottom):  rank 1: C1 V · D1 Wo · E1 El · F1 K · G1 Dw · H1 Hu · I1 V
    //                rank 2: D2 V · E2 Bk · F2 Sp · G2 Bw · H2 V
    //                rank 3: E3 V · F3 V · G3 V
    // Black (top): point-symmetric (col→10-col, row→10-row).

    private mutating func place(_ type: PieceType, _ side: Side, col: Int, row: Int) {
        squares[index(col, row)] = Piece(type: type, side: side, pos: Position(col: col, row: row))
    }

    private mutating func setupStart() {
        // Red
        place(.skjolding, .red, col: 2, row: 0)
        place(.wolf,      .red, col: 3, row: 0)
        place(.elf,       .red, col: 4, row: 0)
        place(.king,      .red, col: 5, row: 0)
        place(.dwarf,     .red, col: 6, row: 0)
        place(.hunter,    .red, col: 7, row: 0)
        place(.skjolding, .red, col: 8, row: 0)
        place(.skjolding, .red, col: 3, row: 1)
        place(.berserker, .red, col: 4, row: 1)
        place(.spearman,  .red, col: 5, row: 1)
        place(.bowman,    .red, col: 6, row: 1)
        place(.skjolding, .red, col: 7, row: 1)
        place(.skjolding, .red, col: 4, row: 2)
        place(.skjolding, .red, col: 5, row: 2)
        place(.skjolding, .red, col: 6, row: 2)

        // Black (point-symmetric)
        place(.skjolding, .black, col: 8, row: 10)
        place(.wolf,      .black, col: 7, row: 10)
        place(.elf,       .black, col: 6, row: 10)
        place(.king,      .black, col: 5, row: 10)
        place(.dwarf,     .black, col: 4, row: 10)
        place(.hunter,    .black, col: 3, row: 10)
        place(.skjolding, .black, col: 2, row: 10)
        place(.skjolding, .black, col: 7, row: 9)
        place(.berserker, .black, col: 6, row: 9)
        place(.spearman,  .black, col: 5, row: 9)
        place(.bowman,    .black, col: 4, row: 9)
        place(.skjolding, .black, col: 3, row: 9)
        place(.skjolding, .black, col: 6, row: 8)
        place(.skjolding, .black, col: 5, row: 8)
        place(.skjolding, .black, col: 4, row: 8)
    }
}

// MARK: - Game State
//
// Owns the live board plus UI-only state (selection, highlights, log) and
// drives the AI opponent. All rules and win logic live in `Board`.

class GameState: ObservableObject {
    /// All positions from the start to the latest played move.
    /// `history[0]` is the opening; `history[i+1]` follows `record[i]`.
    @Published var history: [Board] = [Board()]
    /// Index of the position currently shown on the board.
    @Published var viewIndex: Int = 0
    /// One entry per played move, aligned so `record[i]` produced `history[i+1]`.
    @Published var record: [MoveRecord] = []

    @Published var selected: Position?             = nil
    @Published var highlightMoves: Set<Position>   = []
    @Published var highlightAttacks: Set<Position> = []

    /// Who controls each side.
    @Published var opponent: OpponentMode = .off
    /// Search time budget per move, in seconds.
    @Published var thinkTime: Double = 1.2
    /// Minimum seconds between moves during self-play / replay.
    @Published var stepDelay: Double = 1.0
    /// True while the engine is searching.
    @Published var thinking = false
    /// True while self-play / replay is auto-advancing.
    @Published var isPlaying = false

    /// The live game position (where new moves are appended).
    var liveBoard: Board { history[history.count - 1] }
    /// The position currently displayed (may be in the past while scrubbing).
    var viewedBoard: Board { history[viewIndex] }

    /// Display helpers read the *viewed* board so scrubbing reflects the past.
    var turn: Side          { viewedBoard.sideToMove }
    var winner: Side?       { viewedBoard.winner }
    var winReason: WinReason? { viewedBoard.winReason }

    var atLatest: Bool { viewIndex == history.count - 1 }
    var canStepBack: Bool { viewIndex > 0 }
    var canStepForward: Bool { viewIndex < history.count - 1 }

    init() { reset() }

    // MARK: Public API

    func reset() {
        isPlaying = false
        thinking = false
        history = [Board()]
        viewIndex = 0
        record = []
        selected = nil
        highlightMoves = []
        highlightAttacks = []
        if opponent == .selfPlay {
            play()
        } else {
            maybeScheduleReply()
        }
    }

    func piece(at pos: Position) -> Piece? { viewedBoard.piece(at: pos) }

    func validDestinations(for p: Piece) -> (Set<Position>, Set<Position>) {
        liveBoard.validDestinations(for: p)
    }

    func tap(_ pos: Position) {
        // Taps only act on the live position, for a human-controlled side.
        guard atLatest, liveBoard.winner == nil, !thinking else { return }
        guard controller(of: liveBoard.sideToMove) == .human else { return }

        let tapped = liveBoard.piece(at: pos)
        let stm = liveBoard.sideToMove
        if let sel = selected {
            if sel == pos {
                selected = nil
            } else if let t = tapped, t.side == stm {
                selected = pos
            } else if let p = liveBoard.piece(at: sel) {
                let (m, a) = liveBoard.validDestinations(for: p)
                if m.contains(pos) || a.contains(pos) {
                    perform(Move(from: sel, to: pos, isCapture: a.contains(pos)))
                    return
                }
            }
        } else if let t = tapped, t.side == stm {
            selected = pos
        }
        updateHighlights()
    }

    // MARK: Mode

    func setOpponent(_ mode: OpponentMode) {
        opponent = mode
        selected = nil
        highlightMoves = []
        highlightAttacks = []
        if mode == .selfPlay {
            play()                 // start watching immediately
        } else {
            isPlaying = false
            jumpToLatest()
            maybeScheduleReply()   // single reply if it's now the computer's turn
        }
    }

    private enum Controller { case human, computer }

    private func controller(of side: Side) -> Controller {
        switch opponent {
        case .off:           return .human
        case .computerBlack: return side == .black ? .computer : .human
        case .computerRed:   return side == .red ? .computer : .human
        case .selfPlay:      return .computer
        }
    }

    // MARK: Playback controls

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying else { return }
        // Nothing to advance toward: at the live end with no computer move due.
        if atLatest {
            let live = liveBoard
            let canGenerate = live.winner == nil && controller(of: live.sideToMove) == .computer
            if !canGenerate { return }
        }
        isPlaying = true
        advanceLoop()
    }

    func pause() { isPlaying = false }

    func stepBackward() {
        pause()
        if viewIndex > 0 { viewIndex -= 1 }
        clearSelection()
    }

    func stepForward() {
        if viewIndex < history.count - 1 { viewIndex += 1 }
        clearSelection()
    }

    func jumpToStart() {
        pause()
        viewIndex = 0
        clearSelection()
    }

    func jumpToLatest() {
        viewIndex = history.count - 1
        clearSelection()
    }

    /// Jump the view to a specific ply (0 = opening). Pauses auto-advance.
    func jumpTo(ply: Int) {
        pause()
        viewIndex = max(0, min(history.count - 1, ply))
        clearSelection()
    }

    private func clearSelection() {
        selected = nil
        highlightMoves = []
        highlightAttacks = []
    }

    /// One step of auto-advance: replay a recorded move if the cursor is behind
    /// the live position, otherwise generate the next self-play move (or stop).
    private func advanceLoop() {
        guard isPlaying else { return }

        if viewIndex < history.count - 1 {
            // Replay forward through already-recorded history at a watchable pace.
            DispatchQueue.main.asyncAfter(deadline: .now() + stepDelay) { [weak self] in
                guard let self, self.isPlaying else { return }
                if self.viewIndex < self.history.count - 1 { self.viewIndex += 1 }
                self.advanceLoop()
            }
            return
        }

        // At the live end — generate the next move if a computer is to move.
        let live = liveBoard
        guard live.winner == nil, controller(of: live.sideToMove) == .computer, !thinking else {
            isPlaying = false
            return
        }
        generateEngineMove(minStep: stepDelay) { [weak self] in
            self?.advanceLoop()
        }
    }

    // MARK: Move execution

    private func perform(_ move: Move) {
        let live = liveBoard
        guard let mover = live.piece(at: move.from) else { clearSelection(); return }
        if let blocker = live.piece(at: move.to), blocker.side == mover.side {
            clearSelection(); return
        }

        // Chess-style notation, computed before the board changes.
        let sym = mover.type == .skjolding ? "" : mover.type.symbol
        let cap = live.piece(at: move.to) != nil
        var notation = sym.isEmpty ? "\(move.from)" : "\(sym) \(move.from)"
        notation += cap ? "×\(move.to)" : "-\(move.to)"

        let wasAtLatest = atLatest
        let newBoard = live.applying(move)
        history.append(newBoard)
        record.append(MoveRecord(notation: notation, side: mover.side, reason: newBoard.winReason))

        // Follow the live game unless the user is scrubbing the past.
        if wasAtLatest { viewIndex = history.count - 1 }
        clearSelection()

        if newBoard.winner != nil {
            isPlaying = false
            return
        }
        maybeScheduleReply()
    }

    func winMessage(for side: Side, reason: WinReason?) -> String {
        switch reason {
        case .kingCapture: return "\(side.rawValue) wins — king captured!"
        case .castle:      return "\(side.rawValue) wins — king holds the castle!"
        case .fort:        return "\(side.rawValue) wins — fort control!"
        case .none:        return "\(side.rawValue) wins!"
        }
    }

    // MARK: AI

    /// In single-computer modes, reply to the human as soon as it is the
    /// computer's turn. (Self-play is driven by `advanceLoop` instead.)
    private func maybeScheduleReply() {
        guard opponent == .computerBlack || opponent == .computerRed else { return }
        let live = liveBoard
        guard live.winner == nil, controller(of: live.sideToMove) == .computer, !thinking else { return }
        generateEngineMove(minStep: 0.15) { [weak self] in
            self?.maybeScheduleReply()
        }
    }

    /// Search the live position off the main thread, enforce a minimum elapsed
    /// time so playback stays watchable, then apply the move and call `then`.
    private func generateEngineMove(minStep: Double, then: (() -> Void)? = nil) {
        guard !thinking else { return }
        thinking = true
        let snapshot = liveBoard
        let budget = thinkTime
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let best = Engine.bestMove(for: snapshot, timeLimit: budget)
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < minStep { Thread.sleep(forTimeInterval: minStep - elapsed) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.thinking = false
                // Drop a stale result (game reset or rewound during the search).
                guard self.liveBoard == snapshot, self.liveBoard.winner == nil else { return }
                if let mv = best { self.perform(mv) }
                then?()
            }
        }
    }

    // MARK: Highlights

    private func updateHighlights() {
        guard let sel = selected, let p = liveBoard.piece(at: sel) else {
            highlightMoves = []; highlightAttacks = []; return
        }
        let (m, a) = liveBoard.validDestinations(for: p)
        highlightMoves = m; highlightAttacks = a
    }

    // MARK: File-based command interface
    // Write commands to /tmp/drott_cmd.txt:
    //   "tap F6" · "reset" · "ai black|red|off" · "self" · "play" · "pause"
    //   "back" · "fwd" · "go"

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
        case "ai":
            switch parts.dropFirst().first {
            case "red":   setOpponent(.computerRed)
            case "black": setOpponent(.computerBlack)
            default:      setOpponent(.off)
            }
        case "self":
            setOpponent(.selfPlay)
        case "play":
            play()
        case "pause":
            pause()
        case "back":
            stepBackward()
        case "fwd":
            stepForward()
        case "go":
            // Force a single engine move for the side to move (for testing).
            guard atLatest, liveBoard.winner == nil, !thinking else { return }
            generateEngineMove(minStep: 0)
        default:
            break
        }
    }
}

// Board equality for stale-search detection: compares occupancy and turn state.
extension Board: Equatable {
    static func == (l: Board, r: Board) -> Bool {
        guard l.sideToMove == r.sideToMove,
              l.castleWinPending == r.castleWinPending,
              l.winner == r.winner else { return false }
        for i in 0..<l.squares.count {
            switch (l.squares[i], r.squares[i]) {
            case (nil, nil): continue
            case let (a?, b?): if a.type != b.type || a.side != b.side { return false }
            default: return false
            }
        }
        return true
    }
}
