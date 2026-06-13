import SwiftUI
import AppKit

private let SQ: CGFloat = 54

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        SelfTest.runIfRequested()   // exits the process when DROTT_SELFTEST=1
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
        }
    }
}

// MARK: - App entry

@main
struct DrottApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

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
        .onAppear { game.startCommandListener() }
    }
}

// MARK: - Side panel

private enum SideTab { case game, rules }

/// Maps the opponent segmented control to `GameState.aiSide`.
private enum OpponentChoice: Hashable {
    case human, cpuBlack, cpuRed

    init(aiSide: Side?) {
        switch aiSide {
        case .red:   self = .cpuRed
        case .black: self = .cpuBlack
        case nil:    self = .human
        }
    }
    var aiSide: Side? {
        switch self {
        case .human:    return nil
        case .cpuBlack: return .black
        case .cpuRed:   return .red
        }
    }
}

struct SidePanel: View {
    @ObservedObject var game: GameState
    @State private var tab: SideTab = .game

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Turn / Winner
            infoCard {
                HStack(spacing: 8) {
                    let side = game.winner ?? game.turn
                    Circle()
                        .fill(side == .red ? Color.red : Color.primary)
                        .frame(width: 13, height: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        fieldLabel(game.winner != nil ? "WINNER" : "TURN")
                        Text(side.rawValue).font(.title3.weight(.semibold))
                    }
                    Spacer()
                    if game.thinking {
                        HStack(spacing: 5) {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                            Text("thinking…").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Opponent
            infoCard {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("COMPUTER PLAYS")
                    Picker("", selection: Binding(
                        get: { OpponentChoice(aiSide: game.aiSide) },
                        set: { game.setAI($0.aiSide) }
                    )) {
                        Text("Off").tag(OpponentChoice.human)
                        Text("Black").tag(OpponentChoice.cpuBlack)
                        Text("Red").tag(OpponentChoice.cpuRed)
                    }
                    .pickerStyle(.segmented)

                    if game.aiSide != nil {
                        fieldLabel("STRENGTH")
                        Picker("", selection: Binding(
                            get: { game.thinkTime },
                            set: { game.thinkTime = $0 }
                        )) {
                            Text("Fast").tag(0.4)
                            Text("Normal").tag(1.2)
                            Text("Strong").tag(2.5)
                        }
                        .pickerStyle(.segmented)
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
                    legendRow(color: Color(red: 0.86, green: 0.80, blue: 0.69), label: "Fort area")
                    legendRow(color: Color(red: 0.94, green: 0.90, blue: 0.81), label: "Castle zone")
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
                                    .foregroundStyle(logColor(for: entry))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    private func logColor(for entry: LogEntry) -> Color {
        guard let s = entry.side else { return .secondary }
        return s == .red ? .red : .primary
    }

    // MARK: Rules tab

    private var rulesTab: some View {
        infoCard {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {

                    rulesSection("HOW TO WIN") {
                        """
                        1. Capture the opponent's King.
                        2. Move your King onto the Castle (F6, centre) and survive until it is your turn again.
                        3. Have at least one of your pieces in the opponent's fort while they have no pieces in their own fort.
                        """
                    }

                    rulesSection("MOVEMENT") {
                        """
                        • All pieces move in a straight line to their destination.
                        • No piece may jump over another (except the shieldwall rule below).
                        • Shieldwall: two pieces standing orthogonally adjacent to a diagonal path block that path.
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
                        Bw  Bowman — long range; limited retreat.
                        Bk  Berserker — wide field of action. Limited retreat.
                        El  Elf — king moves or diagonal slide up to 4.
                        Wo  Wolf — orthogonal slide up to 3.
                        Dw  Dwarf — short orthogonal/diagonal + knight shape (no jump).
                        Hu  Hunter — diagonal step + knight shape (no jump).
                        """
                    }

                    rulesSection("STRATEGY NOTES") {
                        """
                        • Control the centre to limit the opponent's King from approaching the Castle.
                        • Develop officers early so flanks aren't open.
                        • Double-advance: officers work best in tandem (Wolf+Elf, Hunter+Dwarf).
                        • King advance can be a winning threat — but leaves your own Fort exposed.
                        • Material advantage? Attack both flanks at once — one must give.
                        """
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
                                    isSelected:     game.selected == pos,
                                    isMoveTarget:   game.highlightMoves.contains(pos),
                                    isAttackTarget: game.highlightAttacks.contains(pos)
                                )
                                .onTapGesture { game.tap(pos) }
                            }
                        }
                    }
                }
                .background(Color(red: 0.16, green: 0.16, blue: 0.18))
                .cornerRadius(4)

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

    private static let normalBeige = Color(red: 0.94, green: 0.90, blue: 0.81)
    private static let fortBeige   = Color(red: 0.86, green: 0.80, blue: 0.69)
    private static let castleGold  = Color(red: 1.0, green: 0.85, blue: 0.2).opacity(0.85)
    private static let textureBrown = Color(red: 0.35, green: 0.22, blue: 0.08)

    private var squareBase: Color {
        if pos == .castle       { return Self.castleGold }
        if Position.isFort(pos) { return Self.fortBeige }
        return Self.normalBeige
    }

    var body: some View {
        ZStack {
            // Tile: rounded rect with shadow, 1px gap on each side
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(squareBase)

                // Castle zone: dot texture
                if Position.isCastleZone(pos) && pos != .castle {
                    castleZoneDots
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // Fort: diagonal line texture
                if Position.isFort(pos) {
                    fortDiagonals
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // Selection tint
                if isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.green.opacity(0.42))
                }

                // Move dot on empty squares
                if isMoveTarget && piece == nil {
                    Circle()
                        .fill(Color.green.opacity(0.55))
                        .frame(width: (SQ - 2) * 0.30, height: (SQ - 2) * 0.30)
                }

                // Piece or coordinate label
                if let p = piece {
                    PieceToken(piece: p)
                } else if !isMoveTarget {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(pos.description)
                                .font(.system(size: 7))
                                .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.08).opacity(0.22))
                                .padding(2)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
            .frame(width: SQ - 2, height: SQ - 2)

            // Attack ring outside tile
            if isAttackTarget {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange, lineWidth: 2)
                    .frame(width: SQ - 2, height: SQ - 2)
            }
        }
        .frame(width: SQ, height: SQ)
    }

    // Dot grid for castle zone
    private var castleZoneDots: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 7
            let r: CGFloat = 0.9
            var x = spacing / 2
            while x < size.width {
                var y = spacing / 2
                while y < size.height {
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect),
                             with: .color(Self.textureBrown.opacity(0.20)))
                    y += spacing
                }
                x += spacing
            }
        }
    }

    // Diagonal lines for fort squares
    private var fortDiagonals: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 7
            var offset: CGFloat = -size.height
            while offset < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
                ctx.stroke(path,
                           with: .color(Self.textureBrown.opacity(0.16)),
                           lineWidth: 0.7)
                offset += spacing
            }
        }
    }
}

// MARK: - Piece token

struct PieceToken: View {
    let piece: Piece

    private var resourceName: String {
        let side = piece.side.rawValue.lowercased()
        let name = piece.type == .skjolding ? "pawn" : piece.type.rawValue
        return "\(side)_\(name)"
    }

    private var nsImage: NSImage? {
        if let resURL = Bundle.main.resourceURL {
            let url = resURL
                .appendingPathComponent("Drott_Drott.bundle")
                .appendingPathComponent("\(resourceName).png")
            if let img = NSImage(contentsOf: url) { return img }
        }
        if let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return nil
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.30), radius: 2, x: 0, y: 1)
                .frame(width: SQ * 0.88, height: SQ * 0.88)

            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: SQ * 0.68, height: SQ * 0.68)
            } else {
                Text(piece.type.symbol)
                    .font(.system(size: SQ * 0.24, weight: .bold, design: .rounded))
                    .foregroundColor(piece.side == .red
                        ? Color(red: 0.72, green: 0.08, blue: 0.08)
                        : Color(red: 0.12, green: 0.12, blue: 0.18))
            }
        }
    }
}
