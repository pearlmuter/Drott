import SwiftUI

private let SQ: CGFloat = 54

// MARK: - App entry

@main
struct DrottApp: App {
    var body: some Scene {
        WindowGroup("Drott") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Content

struct ContentView: View {
    @StateObject private var game = GameState()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            BoardView(game: game)
                .padding(16)
            Divider()
            SidePanel(game: game)
                .frame(width: 220)
                .padding(16)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Side panel

private enum SideTab { case game, rules }

struct SidePanel: View {
    @ObservedObject var game: GameState
    @State private var tab: SideTab = .game

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Turn
            infoCard {
                HStack(spacing: 8) {
                    Circle()
                        .fill(game.turn == .red ? Color.red : Color.primary)
                        .frame(width: 13, height: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        fieldLabel("TURN")
                        Text(game.turn.rawValue).font(.title3.weight(.semibold))
                    }
                }
            }

            // Selected piece
            if let sel = game.selected, let p = game.piece(at: sel) {
                infoCard {
                    VStack(alignment: .leading, spacing: 3) {
                        fieldLabel("SELECTED")
                        Text(p.type.fullName).font(.system(size: 13, weight: .semibold))
                        Text("\(p.side.rawValue)  ·  \(sel.description)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }

            // Tab picker
            Picker("", selection: $tab) {
                Text("Game").tag(SideTab.game)
                Text("Rules").tag(SideTab.rules)
            }
            .pickerStyle(.segmented)

            if tab == .game {
                gameTab
            } else {
                rulesTab
            }

            Spacer()

            Button("New Game") { game.reset() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Game tab

    private var gameTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Legend
            infoCard {
                VStack(alignment: .leading, spacing: 3) {
                    fieldLabel("PIECES")
                    ForEach(PieceType.allCases) { pt in
                        HStack(spacing: 6) {
                            Text(pt.symbol)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .frame(width: 22, alignment: .leading)
                            Text(pt.fullName).font(.system(size: 11))
                        }
                    }
                    Divider().padding(.vertical, 2)
                    fieldLabel("BOARD")
                    legendRow(color: Color(red: 1.0, green: 0.85, blue: 0.2).opacity(0.85), label: "Castle (F6)")
                    legendRow(color: Color(red: 0.55, green: 0.72, blue: 0.95).opacity(0.55), label: "Fort area")
                    legendRow(color: .green.opacity(0.45), label: "Valid move")
                    legendRow(color: .orange.opacity(0.75), label: "Can attack")
                }
            }

            // Move log
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("LOG")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(game.log.reversed()) { entry in
                                Text(entry.text)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    // MARK: Rules tab

    private var rulesTab: some View {
        infoCard {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {

                    rulesSection("HOW TO WIN") {
                        """
                        1. Capture the opponent's King.
                        2. Move any piece into the opponent's Fort (blue area) and survive until your next turn.
                        3. March your King into the Castle (F6) and survive until your next turn. Checking a King already in the Castle won't help — he wins on his next turn regardless.
                        """
                    }

                    rulesSection("MOVEMENT") {
                        """
                        • All pieces move in a straight line to their destination.
                        • No piece may jump over another.
                        • Shieldwall: two pieces standing adjacent to each other (orthogonally or diagonally) block anything from sliding between them.
                        • Capture by landing on the enemy's square. The captured piece is removed.
                        """
                    }

                    rulesSection("SKJOLDING  (V)") {
                        """
                        The most numerous piece. Moves forward toward the opponent. The square directly in front is open — Skjoldings cannot attack straight ahead. Placed diagonally they protect each other. Build chains for a strong line.
                        """
                    }

                    rulesSection("OFFICERS") {
                        """
                        K   King — must be protected. Can enter the Castle to win.
                        Sp  Spearman — limited retreat.
                        Bw  Bowman — long range; limited retreat. Good for covering the Castle from afar.
                        Bk  Berserker — wide field of action; good at chasing the King. Limited retreat. Best used to support Skjolding advances early.
                        El  Elf — dynamic; pairs with Wolf. Works well on the flanks.
                        Wo  Wolf — dynamic; pairs with Elf.
                        Dw  Dwarf — pairs with Hunter.
                        Hu  Hunter — pairs with Dwarf.
                        """
                    }

                    rulesSection("STRATEGY NOTES") {
                        """
                        • Control the centre to limit the opponent's King from approaching the Castle easily.
                        • Develop officers early so flanks aren't open.
                        • Double-advance: officers work best in tandem (Wolf+Elf, Hunter+Dwarf).
                        • King advance can be a winning threat — but leaves your own Fort exposed.
                        • Material advantage? Attack both flanks at once — one must give.
                        """
                    }

                    rulesSection("NOTE") {
                        "Movement ranges per piece are not yet enforced in this app — any straight-line move is currently permitted. To be added."
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 460)
        }
    }

    // MARK: Helpers

    private func rulesSection(_ title: String, _ body: () -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body())
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.15), lineWidth: 0.5))
            Text(label).font(.system(size: 11))
        }
    }

    private func infoCard<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor)))
    }
}

// MARK: - Board

struct BoardView: View {
    @ObservedObject var game: GameState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Row labels  11 … 1
            VStack(spacing: 0) {
                ForEach((0..<11).reversed(), id: \.self) { row in
                    Text("\(row + 1)")
                        .frame(width: 26, height: SQ)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Color.clear.frame(width: 26, height: 26)
            }

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach((0..<11).reversed(), id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<11, id: \.self) { col in
                                let pos = Position(col: col, row: row)
                                SquareView(
                                    pos: pos,
                                    piece: game.piece(at: pos),
                                    isSelected:    game.selected == pos,
                                    isMoveTarget:  game.highlightMoves.contains(pos),
                                    isAttackTarget: game.highlightAttacks.contains(pos)
                                )
                                .onTapGesture { game.tap(pos) }
                            }
                        }
                    }
                }
                .border(Color(red: 0.28, green: 0.18, blue: 0.08).opacity(0.7), width: 2)

                // Column labels  A … K
                HStack(spacing: 0) {
                    ForEach(0..<11, id: \.self) { col in
                        Text(String(UnicodeScalar(65 + col)!))
                            .frame(width: SQ, height: 26)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Square

struct SquareView: View {
    let pos: Position
    let piece: Piece?
    let isSelected: Bool
    let isMoveTarget: Bool
    let isAttackTarget: Bool

    private var bg: Color {
        if isSelected           { return .green.opacity(0.55) }
        if pos == .castle       { return Color(red: 1.0, green: 0.85, blue: 0.2).opacity(0.85) }
        if Position.isFort(pos) { return Color(red: 0.55, green: 0.72, blue: 0.95).opacity(0.55) }
        let light = (pos.col + pos.row) % 2 == 0
        return light
            ? Color(red: 0.94, green: 0.88, blue: 0.77)
            : Color(red: 0.56, green: 0.42, blue: 0.28)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(bg)

            // Move target: green dot on empty squares
            if isMoveTarget && piece == nil {
                Circle()
                    .fill(Color.green.opacity(0.55))
                    .frame(width: SQ * 0.30, height: SQ * 0.30)
            }

            if let p = piece {
                PieceToken(piece: p)
            } else if !isMoveTarget {
                VStack { Spacer()
                    HStack { Spacer()
                        Text(pos.description)
                            .font(.system(size: 7))
                            .foregroundColor(.black.opacity(0.18))
                            .padding(2)
                    }
                }
            }

            // Attack target: orange ring around the whole square
            if isAttackTarget {
                Rectangle()
                    .stroke(Color.orange, lineWidth: 2.5)
            }
        }
        .frame(width: SQ, height: SQ)
        .overlay(Rectangle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - Piece token

struct PieceToken: View {
    let piece: Piece

    private var size: CGFloat { SQ * 0.82 }

    private var fill: Color {
        switch (piece.side, piece.type == .king) {
        case (.red,   true):  return Color(red: 0.80, green: 0.50, blue: 0.05)
        case (.red,   false): return Color(red: 0.72, green: 0.08, blue: 0.08)
        case (.black, true):  return Color(red: 0.35, green: 0.35, blue: 0.44)
        case (.black, false): return Color(red: 0.12, green: 0.12, blue: 0.18)
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(fill).frame(width: size, height: size)
            Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                .frame(width: size, height: size)
            Text(piece.type.symbol)
                .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
    }
}
