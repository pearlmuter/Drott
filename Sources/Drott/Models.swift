import Foundation
import Combine
import CoreGraphics

/// On-screen size of one board square, in points. Updated by GameState when
/// board size changes; shared by views and drag hit-testing.
var SQ: CGFloat = 66   // updated by GameState; both sizes target 594px (9×66 = 11×54)

// MARK: - Board size

// Drott is played on a single 9×9 board. `BoardSize` is kept as a thin type so
// the rest of the code (Board.size, etc.) stays unchanged, but there is only one
// size now.
enum BoardSize: String, CaseIterable, Identifiable {
    case nine = "9×9"
    var id: String { rawValue }
    var N: Int { 9 }
    var squareSize: CGFloat { 66 }   // 9×66 = 594px board
}

// MARK: - Position

struct Position: Equatable, Hashable, CustomStringConvertible {
    let col: Int
    let row: Int

    var colLabel: String { String(UnicodeScalar(65 + col)!) }
    var rowLabel: Int    { row + 1 }
    var description: String { "\(colLabel)\(rowLabel)" }

    // MARK: Castle

    static func castle(N: Int) -> Position { Position(col: N / 2, row: N / 2) }

    // MARK: Fort squares

    static func redFortSquares(N: Int) -> Set<Position> {
        [
            Position(col:2,row:0), Position(col:3,row:0), Position(col:4,row:0),
            Position(col:5,row:0), Position(col:6,row:0),
            Position(col:3,row:1), Position(col:4,row:1), Position(col:5,row:1)
        ]
    }

    static func blackFortSquares(N: Int) -> Set<Position> {
        [
            Position(col:2,row:8), Position(col:3,row:8), Position(col:4,row:8),
            Position(col:5,row:8), Position(col:6,row:8),
            Position(col:3,row:7), Position(col:4,row:7), Position(col:5,row:7)
        ]
    }

    // MARK: Castle zone: 3×3 around the castle plus 3-square orthogonal arms.

    static func isCastleZone(_ p: Position, N: Int) -> Bool {
        let c = castle(N: N)
        if abs(p.col - c.col) <= 1 && abs(p.row - c.row) <= 1 { return true }
        if p.col == c.col && abs(p.row - c.row) <= 3 { return true }
        if p.row == c.row && abs(p.col - c.col) <= 3 { return true }
        return false
    }

    static func valid(col: Int, row: Int, N: Int) -> Bool {
        (0..<N).contains(col) && (0..<N).contains(row)
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
        case .elf:       return "Sw"   // the Sword
        case .wolf:      return "Wo"
        case .dwarf:     return "Ax"   // the Axe
        case .hunter:    return "Hu"
        case .skjolding: return "V"
        }
    }
    // The `elf`/`dwarf` raw values are kept (asset filenames, hashing); only the
    // player-facing names change to "Sword" and "Axe".
    var fullName: String {
        switch self {
        case .elf:   return "Sword"
        case .dwarf: return "Axe"
        default:     return rawValue.capitalized
        }
    }

    /// Compact 1…9 code used for fast position hashing.
    var code: UInt8 {
        switch self {
        case .king:      return 1
        case .berserker: return 2
        case .spearman:  return 3
        case .bowman:    return 4
        case .elf:       return 5
        case .wolf:      return 6
        case .dwarf:     return 7
        case .hunter:    return 8
        case .skjolding: return 9
        }
    }
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
    let move: Move
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
    let size: BoardSize
    var squares: [Piece?]          // count N*N, indexed col + row*N
    var sideToMove: Side
    var winner: Side?
    var winReason: WinReason?

    var N: Int { size.N }

    init(size: BoardSize = .nine) {
        self.size = size
        squares = Array(repeating: nil, count: size.N * size.N)
        sideToMove = .red
        winner = nil
        winReason = nil
        setupStart()
    }

    // MARK: Castle & fort helpers (board-size-aware)

    var castle: Position { Position.castle(N: N) }
    var redFortSquares:   Set<Position> { Position.redFortSquares(N: N) }
    var blackFortSquares: Set<Position> { Position.blackFortSquares(N: N) }

    func isRedFort(_ p: Position)   -> Bool { redFortSquares.contains(p) }
    func isBlackFort(_ p: Position) -> Bool { blackFortSquares.contains(p) }
    func isFort(_ p: Position)      -> Bool { isRedFort(p) || isBlackFort(p) }
    func isFort(_ p: Position, for s: Side) -> Bool { s == .red ? isRedFort(p) : isBlackFort(p) }
    func isCastleZone(_ p: Position) -> Bool { Position.isCastleZone(p, N: N) }

    var pieceCount: (red: Int, black: Int) {
        squares.reduce(into: (0, 0)) { acc, s in
            guard let p = s else { return }
            if p.side == .red { acc.0 += 1 } else { acc.1 += 1 }
        }
    }

    // MARK: Access

    @inline(__always) func index(_ col: Int, _ row: Int) -> Int { col + row * N }
    @inline(__always) func index(_ p: Position) -> Int { p.col + p.row * N }

    /// Returns nil for off-board positions. The movement rules rely on this:
    /// they probe neighbouring squares (e.g. one rank ahead) without bounds
    /// checking first, so an off-board probe must be a safe miss, not a trap.
    func piece(at pos: Position) -> Piece? {
        guard Position.valid(col: pos.col, row: pos.row, N: N) else { return nil }
        return squares[index(pos)]
    }

    /// A deterministic 64-bit key identifying this position for repetition
    /// detection and the transposition table: occupancy (type+side) + side to
    /// move. FNV-1a so it does not depend on Swift's per-run hash seed.
    var repetitionKey: UInt64 {
        var h: UInt64 = 14695981039346656037
        @inline(__always) func mix(_ b: UInt8) { h = (h ^ UInt64(b)) &* 1099511628211 }
        for sq in squares {
            if let p = sq { mix((p.side == .red ? 0 : 100) + p.type.code) } else { mix(0) }
        }
        mix(sideToMove == .red ? 201 : 202)
        return h
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
            generateMoves(for: p) { dest, isCapture in
                result.append(Move(from: p.pos, to: dest, isCapture: isCapture))
            }
        }
        return result
    }

    func captureMoves() -> [Move] {
        var result: [Move] = []
        for sq in squares {
            guard let p = sq, p.side == sideToMove else { continue }
            generateMoves(for: p) { dest, isCapture in
                if isCapture { result.append(Move(from: p.pos, to: dest, isCapture: true)) }
            }
        }
        return result
    }

    // MARK: Apply
    //
    // Returns the board after `move`. Win conditions:
    //   • King capture decides the game immediately for the mover.
    //   • Castle hold and fort control must SURVIVE to the claimant's next turn:
    //     they are won at the *start* of that side's turn. So after applying the
    //     move we switch sides and check whether the new side-to-move already
    //     satisfies a condition — meaning they set it up last turn and it held
    //     through the opponent's reply (who could capture the piece/king or
    //     occupy/defend the fort). The side to move is always switched, even on
    //     a terminal move, so the negamax sign convention stays valid.

    func applying(_ move: Move) -> Board {
        var b = self
        b.winReason = nil
        let fromIdx = index(move.from)
        let toIdx   = index(move.to)
        guard var mover = b.squares[fromIdx] else { return b }
        let moverSide = mover.side

        if let captured = b.squares[toIdx], captured.type == .king {
            b.winner = moverSide
            b.winReason = .kingCapture
        }

        // Relocate the mover.
        mover.pos = move.to
        b.squares[toIdx] = mover
        b.squares[fromIdx] = nil

        // Switch to the opponent — their turn now begins.
        b.sideToMove = moverSide.other

        // A king capture already decided the game.
        if b.winner != nil { return b }

        // The side now to move wins if a castle/fort claim it created last turn
        // has survived to this point.
        let claimant = b.sideToMove
        if b.kingPosition(of: claimant) == b.castle {
            b.winner = claimant
            b.winReason = .castle
        } else if b.hasFortControl(claimant) {
            b.winner = claimant
            b.winReason = .fort
        }

        return b
    }

    /// True if `side` holds the opponent's fort: at least one of its pieces is in
    /// the opponent's fort and the opponent has none of its own pieces there.
    func hasFortControl(_ side: Side) -> Bool {
        let opp = side.other
        var inOpponentFort = false
        var opponentDefends = false
        for sq in squares {
            guard let p = sq else { continue }
            if p.side == side && isFort(p.pos, for: opp) { inOpponentFort = true }
            if p.side == opp  && isFort(p.pos, for: opp) { opponentDefends = true }
        }
        return inOpponentFort && !opponentDefends
    }

    /// Chess-style notation for a move played from this position, e.g.
    /// "Sp F2-G3", "Bk E2×F3", or "E3-E4" (Skjoldings carry no prefix).
    func notation(for move: Move) -> String {
        guard let mover = piece(at: move.from) else { return "\(move.from)-\(move.to)" }
        let sym = mover.type == .skjolding ? "" : mover.type.symbol
        let base = sym.isEmpty ? "\(move.from)" : "\(sym) \(move.from)"
        let capture = piece(at: move.to) != nil
        return base + (capture ? "×\(move.to)" : "-\(move.to)")
    }

    // MARK: Movement rules

    func validDestinations(for p: Piece) -> (Set<Position>, Set<Position>) {
        var moves = Set<Position>(), attacks = Set<Position>()
        generateMoves(for: p) { pos, isCapture in
            if isCapture { attacks.insert(pos) } else { moves.insert(pos) }
        }
        return (moves, attacks)
    }

    /// Number of squares this piece can reach (moves + captures). The engine uses
    /// this as its mobility-based material value — counting via the shared
    /// generator avoids allocating the two Sets that `validDestinations` builds.
    func mobilityCount(for p: Piece) -> Int {
        var n = 0
        generateMoves(for: p) { _, _ in n += 1 }
        return n
    }

    /// Single source of truth for movement: calls `emit(destination, isCapture)`
    /// for every legal destination of `p`. `validDestinations` and
    /// `mobilityCount` are both thin wrappers over this.
    func generateMoves(for p: Piece, emit: (Position, Bool) -> Void) {
        switch p.type {
        case .skjolding:  skjoldingMoves(p, emit)
        case .berserker:  berserkerMoves(p, emit)
        case .spearman:   spearmanMoves(p, emit)
        case .wolf:       wolfMoves(p, emit)
        case .elf:        elfMoves(p, emit)
        case .king:       kingMoves(p, emit)
        case .dwarf:      dwarfMoves(p, emit)
        case .hunter:     hunterMoves(p, emit)
        case .bowman:     bowmanMoves(p, emit)
        }
    }

    @inline(__always)
    private func occupied(_ col: Int, _ row: Int) -> Bool {
        guard Position.valid(col: col, row: row, N: N) else { return false }
        return squares[index(col, row)] != nil
    }

    // Knight-shape move (c,r) → (c+dc, r+dr) where {|dc|,|dr|} == {1,2}.
    // A straight line can thread from origin to target by one of two routes: "high"
    // through A (the long-axis orthogonal square) or "low" through B (the diagonal
    // square). Each route is pinched shut by a pair of diagonally adjacent pieces.
    // The move is blocked if ANY of these three square-pairs is fully occupied:
    //   • {A, B}  — the two middle squares (together fill the crossed file/rank)
    //   • {A, C}  — pinch the origin-side corner (C = short-axis orthogonal step)
    //   • {B, U}  — pinch the target-side corner (U = one square past A toward target)
    private func knightBlocked(_ c: Int, _ r: Int, _ dc: Int, _ dr: Int) -> Bool {
        let sc = dc > 0 ? 1 : -1
        let sr = dr > 0 ? 1 : -1
        let horiz = abs(dc) > abs(dr)
        let a  = occupied(horiz ? c + sc   : c,      horiz ? r : r + sr)    // long-axis orthogonal
        let b  = occupied(c + sc, r + sr)                                   // diagonal
        let cc = occupied(horiz ? c        : c + sc, horiz ? r + sr : r)    // short-axis orthogonal
        let u  = occupied(horiz ? c + 2*sc : c,      horiz ? r : r + 2*sr)  // one past A toward target
        return (a && b) || (a && cc) || (b && u)
    }

    // Skjolding: 2 forward (if 1-forward clear), diagonal forward ×2, 1 backward.
    // Shieldwall: diagonal blocked when both adjacent orthogonals occupied (any piece).
    private func skjoldingMoves(_ p: Piece, _ emit: (Position, Bool) -> Void) {
        let fwd = p.side == .red ? 1 : -1
        let c = p.pos.col, r = p.pos.row

        func add(_ col: Int, _ row: Int) {
            guard Position.valid(col: col, row: row, N: N) else { return }
            let dest = Position(col: col, row: row)
            if let hit = piece(at: dest) {
                if hit.side != p.side { emit(dest, true) }
            } else {
                emit(dest, false)
            }
        }

        if !occupied(c, r + fwd) { add(c, r + 2 * fwd) }
        for dc in [-1, 1] {
            if occupied(c, r + fwd) && occupied(c + dc, r) { continue }
            add(c + dc, r + fwd)
        }
        add(c, r - fwd)
    }

    // Berserker: 3 forward lanes ×3 steps each, 1 sideways. Shieldwall at lane entry.
    private func berserkerMoves(_ p: Piece, _ emit: (Position, Bool) -> Void) {
        let fwd = p.side == .red ? 1 : -1
        let c = p.pos.col, r = p.pos.row

        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row, N: N) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { emit(pos, true) }
                return false
            }
            emit(pos, false); return true
        }

        for step in 1...3 { guard add(c, r + step * fwd) else { break } }
        for dc in [-1, 1] {
            if occupied(c, r + fwd) && occupied(c + dc, r) { continue }
            for step in 1...3 { guard add(c + dc, r + step * fwd) else { break } }
        }
        for dc in [-1, 1] { _ = add(c + dc, r) }
    }

    // Spearman: 3-wide at range 1 (shieldwall on diagonals), spread at range 2, 1 backward.
    private func spearmanMoves(_ p: Piece, _ emit: (Position, Bool) -> Void) {
        let fwd = p.side == .red ? 1 : -1
        let c = p.pos.col, r = p.pos.row

        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row, N: N) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { emit(pos, true) }
                return false
            }
            emit(pos, false); return true
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
    }

    // Wolf: slides orthogonally up to 3 steps in any direction.
    private func wolfMoves(_ p: Piece, _ emit: (Position, Bool) -> Void) {
        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0)] {
            var col = p.pos.col + dc, row = p.pos.row + dr
            for _ in 1...3 {
                guard Position.valid(col: col, row: row, N: N) else { break }
                let pos = Position(col: col, row: row)
                if let hit = piece(at: pos) {
                    if hit.side != p.side { emit(pos, true) }
                    break
                }
                emit(pos, false)
                col += dc; row += dr
            }
        }
    }

    // Elf: 1 step orthogonally in any direction, plus diagonal slide up to 4 steps.
    private func elfMoves(_ p: Piece, _ emit: (Position, Bool) -> Void) {
        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row, N: N) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { emit(pos, true) }
                return false
            }
            emit(pos, false); return true
        }

        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0)] { _ = add(p.pos.col + dc, p.pos.row + dr) }
        for (dc, dr) in [(1,1),(1,-1),(-1,1),(-1,-1)] {
            var col = p.pos.col + dc, row = p.pos.row + dr
            for _ in 1...4 { guard add(col, row) else { break }; col += dc; row += dr }
        }
    }

    // King: 1 step in any of 8 directions.
    private func kingMoves(_ p: Piece, _ emit: (Position, Bool) -> Void) {
        for (dc, dr) in [(0,1),(0,-1),(1,0),(-1,0),(1,1),(1,-1),(-1,1),(-1,-1)] {
            let col = p.pos.col + dc, row = p.pos.row + dr
            guard Position.valid(col: col, row: row, N: N) else { continue }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) { if hit.side != p.side { emit(pos, true) } }
            else { emit(pos, false) }
        }
    }

    // Dwarf: orthogonal slide ≤2, diagonal step 2 only (transit clear), knight-shape (no jump).
    private func dwarfMoves(_ p: Piece, _ emit: (Position, Bool) -> Void) {
        let c = p.pos.col, r = p.pos.row

        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row, N: N) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { emit(pos, true) }
                return false
            }
            emit(pos, false); return true
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
            if knightBlocked(c, r, dc, dr) { continue }
            _ = add(c + dc, r + dr)
        }
    }

    // Hunter: 1 step diagonal (shieldwall), knight-shape (long-axis leg block, no jump).
    private func hunterMoves(_ p: Piece, _ emit: (Position, Bool) -> Void) {
        let c = p.pos.col, r = p.pos.row

        func add(_ col: Int, _ row: Int) {
            guard Position.valid(col: col, row: row, N: N) else { return }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { emit(pos, true) }
            } else {
                emit(pos, false)
            }
        }

        for (dc, dr) in [(1,1),(1,-1),(-1,1),(-1,-1)] {
            if occupied(c, r + dr) && occupied(c + dc, r) { continue }
            add(c + dc, r + dr)
        }
        for (dc, dr) in [(2,1),(2,-1),(-2,1),(-2,-1),(1,2),(1,-2),(-1,2),(-1,-2)] {
            if knightBlocked(c, r, dc, dr) { continue }
            add(c + dc, r + dr)
        }
    }

    // Bowman: slides straight forward up to 4, 1 step sideways each direction.
    private func bowmanMoves(_ p: Piece, _ emit: (Position, Bool) -> Void) {
        let fwd = p.side == .red ? 1 : -1
        let c = p.pos.col, r = p.pos.row

        func add(_ col: Int, _ row: Int) -> Bool {
            guard Position.valid(col: col, row: row, N: N) else { return false }
            let pos = Position(col: col, row: row)
            if let hit = piece(at: pos) {
                if hit.side != p.side { emit(pos, true) }
                return false
            }
            emit(pos, false); return true
        }

        for step in 1...4 { guard add(c, r + step * fwd) else { break } }
        for dc in [-1, 1] { _ = add(c + dc, r) }
    }

    // MARK: Starting positions
    //
    // 9×9 (default):
    //   Red row 0: B1 V · C1 Wo · D1 El · E1 K · F1 Dw · G1 Hu · H1 V
    //   Red row 1: C2 V · D2 Bk · E2 Sp · F2 Bw · G2 V
    //   Black: point-symmetric (col→8-col, row→8-row)

    private mutating func place(_ type: PieceType, _ side: Side, col: Int, row: Int) {
        squares[index(col, row)] = Piece(type: type, side: side, pos: Position(col: col, row: row))
    }

    private mutating func setupStart() {
        // Red
        place(.skjolding, .red, col: 1, row: 0)
        place(.wolf,      .red, col: 2, row: 0)
        place(.elf,       .red, col: 3, row: 0)
        place(.king,      .red, col: 4, row: 0)
        place(.dwarf,     .red, col: 5, row: 0)
        place(.hunter,    .red, col: 6, row: 0)
        place(.skjolding, .red, col: 7, row: 0)
        place(.skjolding, .red, col: 2, row: 1)
        place(.berserker, .red, col: 3, row: 1)
        place(.spearman,  .red, col: 4, row: 1)
        place(.bowman,    .red, col: 5, row: 1)
        place(.skjolding, .red, col: 6, row: 1)
        place(.skjolding, .red, col: 3, row: 2)
        place(.skjolding, .red, col: 4, row: 2)
        place(.skjolding, .red, col: 5, row: 2)

        // Black (point-symmetric: col→8-col, row→8-row)
        place(.skjolding, .black, col: 7, row: 8)
        place(.wolf,      .black, col: 6, row: 8)
        place(.elf,       .black, col: 5, row: 8)
        place(.king,      .black, col: 4, row: 8)
        place(.dwarf,     .black, col: 3, row: 8)
        place(.hunter,    .black, col: 2, row: 8)
        place(.skjolding, .black, col: 1, row: 8)
        place(.skjolding, .black, col: 6, row: 7)
        place(.berserker, .black, col: 5, row: 7)
        place(.spearman,  .black, col: 4, row: 7)
        place(.bowman,    .black, col: 3, row: 7)
        place(.skjolding, .black, col: 2, row: 7)
        place(.skjolding, .black, col: 5, row: 6)
        place(.skjolding, .black, col: 4, row: 6)
        place(.skjolding, .black, col: 3, row: 6)
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
    @Published var viewIndex: Int = 0 {
        didSet { if viewIndex != oldValue { scheduleAnalysis() } }
    }
    /// One entry per played move, aligned so `record[i]` produced `history[i+1]`.
    @Published var record: [MoveRecord] = []

    @Published var selected: Position?             = nil
    @Published var highlightMoves: Set<Position>   = []
    @Published var highlightAttacks: Set<Position> = []

    /// Where we are in the New Game → Start → Finish → Analyse → Engine-analysis
    /// flow. Gates what the UI shows and whether the board accepts input.
    enum Phase { case setup, playing, finished, analysis }
    @Published var phase: Phase = .setup
    /// The eval graph is hidden until the deep "Engine analysis" is requested.
    @Published var showGraph = false

    /// The side that resigned (the other side wins), or nil.
    @Published var concededLoser: Side? = nil
    /// True if the game ended by an agreed draw.
    @Published var drawAgreed = false
    /// A short transient note (e.g. "Draw declined"), shown briefly.
    @Published var statusMessage: String? = nil

    /// Board size for the next (or current) game.
    @Published var boardSize: BoardSize = .nine

    /// Who controls each side.
    @Published var opponent: OpponentMode = .off
    /// Search time budget per move, in seconds — the engine's strength setting
    /// (Easy 2 / Normal 5 / Hard 10). Longer thinking = stronger play.
    @Published var thinkTime: Double = 5.0
    /// Fixed pace (seconds) for stepping through already-recorded history during
    /// self-play replay. Live moves are paced by `thinkTime` itself.
    private let replayStepDelay: Double = 0.6
    /// True while the engine is searching.
    @Published var thinking = false
    /// True while self-play / replay is auto-advancing.
    @Published var isPlaying = false

    /// History index at which the game was drawn by threefold repetition (nil =
    /// no draw). The draw is shown only when viewing that final position.
    @Published var drawPly: Int? = nil

    // Drag-to-move state (nil origin = no drag in progress).
    @Published var dragOrigin: Position? = nil
    @Published var dragTranslation: CGSize = .zero

    // Background analysis of the *viewed* position, for the eval bar / read-out.
    @Published var evalEnabled = true
    @Published var evalRed: Int? = nil          // score from Red's perspective
    @Published var lineHighlight: (from: Position, to: Position)? = nil
    @Published var analysis: SearchResult? = nil
    @Published var analysisTurn: Side = .red    // side to move in the analysed pos
    private var analysisGen = 0
    private let analysisQueue = DispatchQueue(label: "drott.analysis", qos: .userInitiated)
    /// The live eval is searched as deeply as the playing engine so it is stable
    /// (a shallow eval swings wildly between transient threats).
    private let analysisTime = 1.2

    // Evaluation graph: Red-perspective eval per ply (index aligned with
    // `history`; nil = unknown). Populated live during the game with the engine's
    // own contemporary evaluation, then optionally overwritten one position at a
    // time by a deeper (5s, depth ≤22) re-analysis.
    @Published var graphScores: [Int?] = [nil]
    @Published var deepAnalyzing = false
    @Published var deepProgress = 0             // positions deep-analysed so far
    @Published var deepTotal = 0
    @Published var deepTimePerMove: Double = 5.0
    private var deepGen = 0
    private let deepQueue = DispatchQueue(label: "drott.deepanalysis", qos: .userInitiated)
    static let analysisDepthCap = 22

    /// The live game position (where new moves are appended).
    var liveBoard: Board { history[history.count - 1] }
    /// The position currently displayed (may be in the past while scrubbing).
    var viewedBoard: Board { history[viewIndex] }

    /// Convenience: board dimension for the current game.
    var boardN: Int { liveBoard.N }

    /// Pieces captured by each side (compared to the starting position).
    var capturedCounts: (byRed: Int, byBlack: Int) {
        let initial = Board(size: boardSize).pieceCount
        let current = liveBoard.pieceCount
        return (byRed: initial.black - current.black, byBlack: initial.red - current.red)
    }

    /// Display helpers read the *viewed* board so scrubbing reflects the past.
    var turn: Side          { viewedBoard.sideToMove }
    var winner: Side?       { viewedBoard.winner }
    var winReason: WinReason? { viewedBoard.winReason }

    var atLatest: Bool { viewIndex == history.count - 1 }
    var canStepBack: Bool { viewIndex > 0 }
    var canStepForward: Bool { viewIndex < history.count - 1 }

    /// The game has ended (a side won, was drawn, was resigned, or drawn by
    /// agreement).
    var isGameOver: Bool {
        liveBoard.winner != nil || drawPly != nil || concededLoser != nil || drawAgreed
    }
    /// Viewing the last (final) position.
    var viewingFinal: Bool { viewIndex == history.count - 1 }

    // MARK: Result for display (considers board result + resignation/agreement)

    /// The winning side to show for the viewed position, if decided.
    var displayWinner: Side? {
        if let w = viewedBoard.winner { return w }
        if viewingFinal, let loser = concededLoser { return loser.other }
        return nil
    }
    /// Whether the viewed position is a drawn ending.
    var isDrawShown: Bool {
        if drawPly != nil && viewIndex == drawPly { return true }
        if viewingFinal, drawAgreed { return true }
        return false
    }
    /// Human-readable ending for the viewed position, if it is a finished one.
    var resultMessage: String? {
        if let w = viewedBoard.winner { return winMessage(for: w, reason: viewedBoard.winReason) }
        if drawPly != nil && viewIndex == drawPly { return "Draw — threefold repetition" }
        guard viewingFinal else { return nil }
        if let loser = concededLoser { return "\(loser.other.rawValue) wins — \(loser.rawValue) resigned" }
        if drawAgreed { return "Draw — agreed" }
        return nil
    }

    /// Which side a human controls (the resigning / draw-offering side), or nil.
    var humanSide: Side? {
        switch opponent {
        case .computerBlack: return .red
        case .computerRed:   return .black
        case .off:           return liveBoard.sideToMove
        case .selfPlay:      return nil
        }
    }
    /// Resign / draw offers are available while a human is playing.
    var canOfferResultControls: Bool { phase == .playing && !isGameOver && humanSide != nil }

    /// The move that produced the currently-viewed position (for highlighting).
    var lastMove: Move? { viewIndex >= 1 ? record[viewIndex - 1].move : nil }

    /// The piece currently being dragged (on the live board), if any.
    var draggedPiece: Piece? { dragOrigin.flatMap { interactiveBoard.piece(at: $0) } }

    /// True if the latest position in `history` has occurred three times.
    static func isThreefoldRepetition(in history: [Board]) -> Bool {
        guard let last = history.last else { return false }
        return history.reduce(0) { $0 + ($1 == last ? 1 : 0) } >= 3
    }

    init() { reset() }

    // MARK: Public API

    /// "New Game": clear the board and return to the setup phase. Does NOT start
    /// play — the computer only moves once the user presses Start Game.
    func reset() {
        SQ = boardSize.squareSize
        isPlaying = false
        thinking = false
        history = [Board(size: boardSize)]
        viewIndex = 0
        record = []
        drawPly = nil
        selected = nil
        highlightMoves = []
        highlightAttacks = []
        lineHighlight = nil
        cancelDeepAnalysis()
        graphScores = [nil]            // one slot for the opening position
        showGraph = false
        concededLoser = nil
        drawAgreed = false
        statusMessage = nil
        phase = .setup
        scheduleAnalysis()
    }

    /// Change the board size during setup. Refreshes the starting position.
    func setBoardSize(_ s: BoardSize) {
        guard phase == .setup else { return }
        boardSize = s
        SQ = s.squareSize
        history = [Board(size: s)]
        viewIndex = 0
        record = []
        graphScores = [nil]
        lineHighlight = nil
        clearSelection()
        scheduleAnalysis()
    }

    // MARK: Save / load (play-by-mail and practice positions)

    /// The moves played so far as a small, human-readable text file. Each move
    /// keeps its notation, so the file doubles as a readable game score; import
    /// only needs the square coordinates within it.
    func exportGame() -> String {
        var out = "Drott 9×9\n"
        var i = 0
        var moveNo = 1
        while i < record.count {
            var line = "\(moveNo). \(record[i].notation)"
            i += 1
            if i < record.count {            // pair Black's reply on the same line
                line += "   \(record[i].notation)"
                i += 1
            }
            out += line + "\n"
            moveNo += 1
        }
        return out
    }

    /// Rebuild a game from text produced by `exportGame` (or any text containing
    /// the moves as square pairs, e.g. "E2-E4  D8-D6"). Returns false without
    /// changing anything if a move is illegal from the position it reaches.
    @discardableResult
    func importGame(from text: String) -> Bool {
        let squares = GameState.parseSquares(text)
        guard squares.count >= 2, squares.count % 2 == 0 else { return false }

        var boards: [Board] = [Board()]
        var moves: [MoveRecord] = []
        var board = boards[0]
        var i = 0
        while i + 1 < squares.count {
            let from = squares[i], to = squares[i + 1]
            i += 2
            guard board.legalMoves().contains(where: { $0.from == from && $0.to == to }) else {
                return false
            }
            let mv = Move(from: from, to: to, isCapture: board.piece(at: to) != nil)
            let side = board.sideToMove
            let notation = board.notation(for: mv)
            board = board.applying(mv)
            moves.append(MoveRecord(move: mv, notation: notation, side: side,
                                    reason: board.winner != nil ? board.winReason : nil))
            boards.append(board)
        }

        // Commit: load the position and let the user continue (or analyse, if the
        // imported game is already decided). Both sides are human after import.
        isPlaying = false
        thinking = false
        cancelDeepAnalysis()
        opponent = .off
        SQ = boardSize.squareSize
        history = boards
        record = moves
        viewIndex = boards.count - 1
        graphScores = Array(repeating: nil, count: boards.count)
        showGraph = false
        drawPly = nil
        concededLoser = nil
        drawAgreed = false
        statusMessage = nil
        lineHighlight = nil
        clearSelection()
        phase = board.winner != nil ? .finished : .playing
        scheduleAnalysis()
        return true
    }

    /// Extract board squares (a letter A–I followed by a digit 1–9) in order,
    /// ignoring move numbers, piece symbols and punctuation.
    static func parseSquares(_ text: String) -> [Position] {
        var result: [Position] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            defer { i += 1 }
            guard let ascii = chars[i].uppercased().first?.asciiValue,
                  ascii >= 65, ascii <= 73,                       // A…I
                  i + 1 < chars.count,
                  let row = chars[i + 1].wholeNumberValue, (1...9).contains(row)
            else { continue }
            result.append(Position(col: Int(ascii - 65), row: row - 1))
            i += 1   // consume the digit too
        }
        return result
    }

    /// "Start Game": leave setup and begin play with the chosen options.
    func startGame() {
        guard phase == .setup else { return }
        phase = .playing
        if opponent == .selfPlay {
            play()
        } else {
            maybeScheduleReply()   // computer opens if it controls the first move
        }
    }

    /// "Analyse game": after the game is over, enter analysis — move pieces freely
    /// and watch the engine evaluation change. The deep graph stays hidden until
    /// "Engine analysis" is requested.
    func beginAnalysis() {
        guard phase == .finished else { return }
        phase = .analysis
        jumpToStart()              // start the review at the opening
    }

    /// "Engine analysis": run the deep per-position sweep and reveal the graph.
    func runEngineAnalysis() {
        guard phase == .analysis else { return }
        showGraph = true
        analyzeGame()
    }

    // MARK: Resign & draw

    /// The human resigns; the opposing side wins and the game ends.
    func resign() {
        guard canOfferResultControls, let loser = humanSide else { return }
        concededLoser = loser
        isPlaying = false
        if !graphScores.isEmpty {
            graphScores[history.count - 1] = (loser.other == .red) ? Engine.mate : -Engine.mate
        }
        statusMessage = nil
        phase = .finished
        clearSelection()
        scheduleAnalysis()
    }

    /// The human offers a draw. Against another human it is simply agreed;
    /// against the computer it is accepted only if the computer is not winning.
    func offerDraw() {
        guard canOfferResultControls else { return }
        switch opponent {
        case .off:
            agreeDraw()
        case .computerBlack, .computerRed:
            guard let computer = humanSide?.other else { return }
            let snapshot = liveBoard
            let pastBoards = history
            statusMessage = "Offering a draw…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Engine.search(snapshot, history: pastBoards, timeLimit: 0.6)
                // Score from the computer's perspective.
                let computerEval = snapshot.sideToMove == computer ? result.score : -result.score
                DispatchQueue.main.async {
                    guard let self, self.canOfferResultControls, self.liveBoard == snapshot else {
                        self?.statusMessage = nil; return
                    }
                    // Accept if the computer is not clearly better (≤ ~0.5 pawn).
                    if computerEval <= 50 {
                        self.agreeDraw()
                    } else {
                        self.statusMessage = "Draw declined"
                    }
                }
            }
        case .selfPlay:
            return
        }
    }

    private func agreeDraw() {
        drawAgreed = true
        isPlaying = false
        if !graphScores.isEmpty { graphScores[history.count - 1] = 0 }
        statusMessage = nil
        phase = .finished
        clearSelection()
        scheduleAnalysis()
    }

    func piece(at pos: Position) -> Piece? { viewedBoard.piece(at: pos) }

    func validDestinations(for p: Piece) -> (Set<Position>, Set<Position>) {
        liveBoard.validDestinations(for: p)
    }

    /// Notation for a candidate move in the currently-viewed position.
    func notation(for move: Move) -> String { viewedBoard.notation(for: move) }

    /// The board the user can currently move on: the live game while playing, or
    /// the viewed position while analysing (so variations branch from anywhere).
    var interactiveBoard: Board { phase == .analysis ? viewedBoard : liveBoard }

    /// True if the user may move a piece right now.
    private var canInteract: Bool {
        guard !thinking else { return false }
        switch phase {
        case .playing:  return atLatest && !isGameOver && controller(of: liveBoard.sideToMove) == .human
        case .analysis: return true        // free exploration of either side
        case .setup, .finished: return false
        }
    }

    func tap(_ pos: Position) {
        guard canInteract else { return }
        let board = interactiveBoard
        let tapped = board.piece(at: pos)
        let stm = board.sideToMove
        if let sel = selected {
            if sel == pos {
                selected = nil
            } else if let t = tapped, t.side == stm {
                selected = pos
            } else if let p = board.piece(at: sel) {
                let (m, a) = board.validDestinations(for: p)
                if m.contains(pos) || a.contains(pos) {
                    makeMove(Move(from: sel, to: pos, isCapture: a.contains(pos)))
                    return
                }
            }
        } else if let t = tapped, t.side == stm {
            selected = pos
        }
        updateHighlights()
    }

    /// Play a move. While analysing a past position, branch by dropping the
    /// future first so the move starts a fresh variation.
    private func makeMove(_ move: Move) {
        if phase == .analysis && !atLatest {
            let keep = viewIndex
            history = Array(history.prefix(keep + 1))
            record  = Array(record.prefix(keep))
            graphScores = Array(graphScores.prefix(keep + 1))
            drawPly = nil
        }
        perform(move)
    }

    // MARK: Drag to move

    /// Called continuously as a piece is dragged. Picks up the piece on first
    /// movement (lighting up its legal targets) and tracks the cursor offset.
    func dragChanged(from pos: Position, translation: CGSize) {
        guard canInteract else { return }
        let board = interactiveBoard
        if dragOrigin == nil {
            guard let p = board.piece(at: pos), p.side == board.sideToMove else { return }
            dragOrigin = pos
            selected = pos
            updateHighlights()
        }
        dragTranslation = translation
    }

    /// The square a drag lands on, given the start square and the cursor offset.
    /// Screen y grows downward but board rows grow upward, hence the negation.
    static func dropTarget(from pos: Position, translation: CGSize) -> Position {
        let dCol = Int((translation.width  / SQ).rounded())
        let dRow = Int((-translation.height / SQ).rounded())
        return Position(col: pos.col + dCol, row: pos.row + dRow)
    }

    /// Called when a drag ends. Drops the piece on the nearest square and plays
    /// the move if it is legal; otherwise the piece snaps back.
    func dragEnded(from pos: Position, translation: CGSize) {
        defer { dragOrigin = nil; dragTranslation = .zero }
        let board = interactiveBoard
        guard dragOrigin == pos, let p = board.piece(at: pos) else { return }

        let target = GameState.dropTarget(from: pos, translation: translation)
        guard Position.valid(col: target.col, row: target.row, N: board.N) else {
            clearSelection(); return
        }
        let (m, a) = board.validDestinations(for: p)
        if m.contains(target) || a.contains(target) {
            makeMove(Move(from: pos, to: target, isCapture: a.contains(target)))
        } else {
            clearSelection()
        }
    }

    // MARK: Analysis (eval read-out)

    /// Re-analyse the *viewed* position in the background, superseding any
    /// in-flight analysis. Publishes a Red-perspective score and the top lines.
    func scheduleAnalysis() {
        analysisGen += 1
        guard evalEnabled else { evalRed = nil; analysis = nil; return }

        let board = viewedBoard
        let turn = board.sideToMove
        analysisTurn = turn

        if isDrawShown {
            evalRed = 0
            analysis = nil
            return
        }
        if let w = displayWinner {
            evalRed = (w == .red) ? Engine.mate : -Engine.mate
            analysis = nil
            return
        }

        let gen = analysisGen
        let budget = analysisTime
        let past = Array(history.prefix(viewIndex + 1))   // positions up to the view
        analysisQueue.async { [weak self] in
            let result = Engine.search(board, history: past, timeLimit: budget)
            DispatchQueue.main.async {
                guard let self, self.analysisGen == gen else { return }
                self.analysis = result
                self.analysisTurn = turn
                self.evalRed = (turn == .red) ? result.score : -result.score
            }
        }
    }

    // MARK: Deep post-game analysis (the eval graph)

    /// Re-analyse every position in the game with a deeper search (5s, depth ≤22)
    /// and overwrite the graph one position at a time, replacing the contemporary
    /// in-game evaluations as it goes.
    func analyzeGame() {
        guard phase == .analysis, history.count > 1 else { return }
        deepGen += 1
        let gen = deepGen
        let boards = history
        let n = boards.count
        let drawAt = drawPly
        let budget = deepTimePerMove

        // Keep the contemporary values on screen; they are replaced in place.
        if graphScores.count != n { graphScores = Array(repeating: nil, count: n) }
        deepProgress = 0
        deepTotal = n
        deepAnalyzing = true

        deepQueue.async { [weak self] in
            for i in 0..<n {
                // Cancellation check, race-free, without retaining self across
                // the long search below.
                var stillCurrent = false
                DispatchQueue.main.sync { stillCurrent = (self?.deepGen == gen) }
                guard stillCurrent else { return }

                let board = boards[i]
                let red: Int
                if let w = board.winner {
                    red = (w == .red) ? Engine.mate : -Engine.mate
                } else if drawAt == i {
                    red = 0
                } else {
                    let prefix = Array(boards.prefix(i + 1))
                    let r = Engine.search(board, history: prefix, timeLimit: budget,
                                          depthLimit: GameState.analysisDepthCap)
                    red = (board.sideToMove == .red) ? r.score : -r.score
                }

                DispatchQueue.main.async {
                    guard let self, self.deepGen == gen else { return }
                    if i < self.graphScores.count { self.graphScores[i] = red }
                    self.deepProgress = i + 1
                    if i == n - 1 { self.deepAnalyzing = false }
                }
            }
        }
    }

    func cancelAnalysis() { cancelDeepAnalysis() }

    /// Stop any in-progress deep analysis (keeps the graph data already gathered).
    private func cancelDeepAnalysis() {
        deepGen += 1
        deepAnalyzing = false
        deepProgress = 0
        deepTotal = 0
    }

    // MARK: Mode

    /// Choose who controls each side. Does NOT start play — the user presses
    /// "Start Game" once the options are set.
    func setOpponent(_ mode: OpponentMode) {
        opponent = mode
        isPlaying = false
        selected = nil
        highlightMoves = []
        highlightAttacks = []
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
            let canGenerate = !isGameOver && controller(of: live.sideToMove) == .computer
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
            DispatchQueue.main.asyncAfter(deadline: .now() + replayStepDelay) { [weak self] in
                guard let self, self.isPlaying else { return }
                if self.viewIndex < self.history.count - 1 { self.viewIndex += 1 }
                self.advanceLoop()
            }
            return
        }

        // At the live end — generate the next move if a computer is to move
        // (only while actually playing; replay/analysis never generates).
        let live = liveBoard
        guard phase == .playing, !isGameOver,
              controller(of: live.sideToMove) == .computer, !thinking else {
            isPlaying = false
            return
        }
        generateEngineMove(minStep: 0.15) { [weak self] in
            self?.advanceLoop()
        }
    }

    // MARK: Move execution

    /// `contemporaryEval` is the engine's Red-perspective evaluation of the
    /// position being moved from (passed by the AI; nil for human moves, where
    /// the live eval is used instead) — recorded for the game eval graph.
    private func perform(_ move: Move, contemporaryEval: Int? = nil) {
        let live = liveBoard
        guard let mover = live.piece(at: move.from) else { clearSelection(); return }
        if let blocker = live.piece(at: move.to), blocker.side == mover.side {
            clearSelection(); return
        }

        // Chess-style notation, computed before the board changes.
        let notation = live.notation(for: move)

        // A new move supersedes any in-progress deep analysis, but the graph of
        // already-recorded evaluations is kept and extended.
        cancelDeepAnalysis()
        statusMessage = nil

        let fromIndex = history.count - 1
        let wasAtLatest = atLatest
        let newBoard = live.applying(move)
        history.append(newBoard)
        record.append(MoveRecord(move: move, notation: notation, side: mover.side,
                                 reason: newBoard.winReason))

        // Remember the engine's view of the position just played from, and add a
        // slot for the new position (filled when it is moved from, or analysed).
        graphScores[fromIndex] = contemporaryEval ?? evalRed
        graphScores.append(nil)

        // Threefold repetition is a draw.
        if newBoard.winner == nil, GameState.isThreefoldRepetition(in: history) {
            drawPly = history.count - 1
        }

        // Follow the live game unless the user is scrubbing the past.
        if wasAtLatest { viewIndex = history.count - 1 }
        clearSelection()

        if isGameOver {
            isPlaying = false
            // Terminal positions have a decisive eval.
            if let w = newBoard.winner {
                graphScores[history.count - 1] = (w == .red) ? Engine.mate : -Engine.mate
            } else {
                graphScores[history.count - 1] = 0   // draw
            }
            // A real game ending moves us to the finished phase (exploring a
            // variation into a terminal position stays in analysis).
            if phase == .playing { phase = .finished }
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
        guard phase == .playing else { return }
        guard opponent == .computerBlack || opponent == .computerRed else { return }
        guard !isGameOver, controller(of: liveBoard.sideToMove) == .computer, !thinking else { return }
        generateEngineMove(minStep: 0.15) { [weak self] in
            self?.maybeScheduleReply()
        }
    }

    /// Search the live position off the main thread, enforce a minimum elapsed
    /// time so playback stays watchable, then apply the chosen move and call
    /// `then`. Uses the multi-line result so play can vary (occasional 2nd-best).
    private func generateEngineMove(minStep: Double, then: (() -> Void)? = nil) {
        guard !thinking else { return }
        thinking = true
        let snapshot = liveBoard
        let pastBoards = history          // includes the live board; for repetition
        let budget = thinkTime
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Engine.search(snapshot, history: pastBoards, timeLimit: budget)
            // The strongest setting (Hard, 10s) plays the best move deterministically;
            // easier settings vary for non-determinism, guarded against hanging.
            let chosen = Engine.pickMove(from: result, on: snapshot, allowVariety: budget < 10)
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < minStep { Thread.sleep(forTimeInterval: minStep - elapsed) }
            // The engine's view of this position, from Red's perspective, for
            // the game eval graph.
            let redEval = snapshot.sideToMove == .red ? result.score : -result.score
            DispatchQueue.main.async {
                guard let self else { return }
                self.thinking = false
                // Drop a stale result (game reset or rewound during the search).
                guard self.liveBoard == snapshot, !self.isGameOver else { return }
                if let mv = chosen { self.perform(mv, contemporaryEval: redEval) }
                then?()
            }
        }
    }

    /// Toggle background analysis (the eval read-out).
    func setEvalEnabled(_ on: Bool) {
        evalEnabled = on
        scheduleAnalysis()
    }

    // MARK: Highlights

    private func updateHighlights() {
        let board = interactiveBoard
        guard let sel = selected, let p = board.piece(at: sel) else {
            highlightMoves = []; highlightAttacks = []; return
        }
        let (m, a) = board.validDestinations(for: p)
        highlightMoves = m; highlightAttacks = a
    }

    // MARK: File-based command interface
    // Write commands to /tmp/drott_cmd.txt:
    //   "tap F6" · "reset" · "ai black|red|off" · "self" · "play" · "pause"
    //   "back" · "fwd" · "go" · "size 9" · "size 11"

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
        let n = liveBoard.N
        switch verb {
        case "tap":
            guard let posStr = parts.dropFirst().first, posStr.count == 2,
                  let colChar = posStr.first?.uppercased().first,
                  let colAscii = colChar.asciiValue,
                  colAscii >= 65, colAscii < 65 + UInt8(n),
                  let rowNum = Int(posStr.dropFirst()),
                  (1...n).contains(rowNum) else { return }
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
        case "start":
            startGame()
        case "review", "analysegame":
            beginAnalysis()
        case "analyze", "analyse", "engine":
            runEngineAnalysis()
        case "resign":
            resign()
        case "draw":
            offerDraw()
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
            guard atLatest, !isGameOver, !thinking else { return }
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
              l.winner == r.winner,
              l.N == r.N else { return false }
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
