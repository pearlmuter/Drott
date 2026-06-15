import SwiftUI
import AppKit
import UniformTypeIdentifiers

// `SQ` (square size) is defined in Models.swift and shared with drag hit-testing.

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        SelfTest.runIfRequested()      // exits the process when DROTT_SELFTEST=1
        AppIcon.exportIfRequested()    // exits the process when DROTT_MAKEICON=1
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIcon.applyToDock()
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
            VStack(alignment: .leading, spacing: 12) {
                BoardView(game: game)
                if game.showGraph {
                    GameGraphPanel(game: game)
                }
            }
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

// MARK: - Game eval graph (under the board)

struct GameGraphPanel: View {
    @ObservedObject var game: GameState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("ENGINE ANALYSIS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if game.deepAnalyzing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        Text("\(game.deepProgress)/\(game.deepTotal) · \(GameGraphPanel.deepSeconds(game.deepTimePerMove))s/move")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Button("Stop") { game.cancelAnalysis() }
                            .controlSize(.small)
                    }
                } else {
                    Text("deep \(GameGraphPanel.deepSeconds(game.deepTimePerMove))s/move · depth ≤\(GameState.analysisDepthCap)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            EvalGraph(scores: game.graphScores, current: game.viewIndex) { ply in
                game.jumpTo(ply: ply)
            }
            .frame(height: 96)

            Text("Red above the midline, Black below · click to jump to a move")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(width: SQ * CGFloat(game.boardN) + 30)   // match the board's width
    }

    static func deepSeconds(_ t: Double) -> String {
        t == t.rounded() ? String(Int(t)) : String(format: "%.1f", t)
    }
}

// MARK: - Side panel

private enum SideTab { case game, rules }

struct SidePanel: View {
    @ObservedObject var game: GameState
    @State private var tab: SideTab = .game
    @State private var legendExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            statusCard

            // Settings + Start Game only during setup.
            if game.phase == .setup {
                settingsCard
            }

            // Resign / draw while a human is playing.
            if game.canOfferResultControls {
                HStack(spacing: 8) {
                    Button("Resign") { game.resign() }
                        .frame(maxWidth: .infinity)
                    Button("Offer draw") { game.offerDraw() }
                        .frame(maxWidth: .infinity)
                }
            }

            // Playback / scrubbing once there are moves to review.
            if game.record.count > 0 {
                playbackCard
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

            // Save / load games (play-by-mail, practice positions).
            HStack(spacing: 8) {
                Button { saveGame() } label: {
                    Label("Save", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .disabled(game.record.isEmpty)
                Button { loadGame() } label: {
                    Label("Load", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.small)

            // Tab picker
            Picker("", selection: $tab) {
                Text("Game").tag(SideTab.game)
                Text("Rules").tag(SideTab.rules)
            }
            .pickerStyle(.segmented)

            switch tab {
            case .game:  gameTab
            case .rules: rulesTab
            }

            Spacer()

            // Phase action buttons — not shown in setup (Start Game is inside settingsCard).
            if game.phase != .setup {
                phaseButtons
            }
        }
    }

    // Turn / result, plus any transient status note.
    private var statusCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if game.isDrawShown {
                        pillBadge("Draw", color: .secondary)
                        Text("agreed").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        let side = game.displayWinner ?? game.turn
                        let label = game.displayWinner != nil ? "WINNER" : "TURN"
                        pillBadge(side.rawValue, color: side == .red ? Color(red:0.75,green:0.13,blue:0.11) : Color(red:0.14,green:0.14,blue:0.18))
                        Text(label == "WINNER" ? "wins" : "to move")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if game.thinking {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                            Text("thinking…").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }

                // Captured piece tally — only meaningful once game starts.
                if game.phase != .setup {
                    let caps = game.capturedCounts
                    HStack(spacing: 14) {
                        capturedLabel(side: "Red",   taken: caps.byBlack)
                        capturedLabel(side: "Black", taken: caps.byRed)
                    }
                }

                if let msg = game.statusMessage {
                    Text(msg).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pillBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(color))
    }

    private func capturedLabel(side: String, taken: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(side == "Red" ? Color(red:0.75,green:0.13,blue:0.11) : Color(red:0.14,green:0.14,blue:0.18))
                .frame(width: 7, height: 7)
            Text(side).font(.system(size: 10)).foregroundStyle(.secondary)
            Text("−\(taken)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(taken > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
    }

    // Opponent / strength — setup only.
    private var settingsCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("COMPUTER PLAYS")
                Picker("", selection: Binding(
                    get: { game.opponent },
                    set: { game.setOpponent($0) }
                )) {
                    Text("Off").tag(OpponentMode.off)
                    Text("Black").tag(OpponentMode.computerBlack)
                    Text("Red").tag(OpponentMode.computerRed)
                    Text("Self").tag(OpponentMode.selfPlay)
                }
                .pickerStyle(.segmented)

                if game.opponent != .off {
                    fieldLabel("STRENGTH")
                    Picker("", selection: Binding(
                        get: { game.thinkTime },
                        set: { game.thinkTime = $0 }
                    )) {
                        Text("Easy").tag(2.0)
                        Text("Normal").tag(5.0)
                        Text("Hard").tag(10.0)
                    }
                    .pickerStyle(.segmented)
                }

                Divider().padding(.vertical, 2)

                Button("Start Game") { game.startGame() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // Primary action button(s) per phase (setup is handled inside settingsCard).
    @ViewBuilder
    private var phaseButtons: some View {
        switch game.phase {
        case .setup:
            EmptyView()
        case .playing:
            Button("New Game") { game.reset() }
                .frame(maxWidth: .infinity)
        case .finished:
            VStack(spacing: 8) {
                Button("Analyse game") { game.beginAnalysis() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                Button("New Game") { game.reset() }
                    .frame(maxWidth: .infinity)
            }
        case .analysis:
            VStack(spacing: 8) {
                Button(game.showGraph ? "Re-run engine analysis" : "Engine analysis") {
                    game.runEngineAnalysis()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(game.deepAnalyzing)
                Button("New Game") { game.reset() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Playback controls

    private var playbackCard: some View {
        infoCard {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    pbButton("backward.end.fill", enabled: game.canStepBack,
                             key: .leftArrow, modifiers: .command) { game.jumpToStart() }
                    pbButton("backward.fill", enabled: game.canStepBack,
                             key: .leftArrow) { game.stepBackward() }
                    pbButton(game.isPlaying ? "pause.fill" : "play.fill", enabled: true,
                             key: .space) { game.togglePlay() }
                    pbButton("forward.fill", enabled: game.canStepForward,
                             key: .rightArrow) { game.stepForward() }
                    pbButton("forward.end.fill", enabled: game.canStepForward,
                             key: .rightArrow, modifiers: .command) { game.jumpToLatest() }
                }
                Text("Move \(game.viewIndex) / \(game.record.count)   ·   ← →")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func pbButton(_ symbol: String, enabled: Bool,
                          key: KeyEquivalent? = nil, modifiers: EventModifiers = [],
                          action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 30, height: 22)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)

        if let key {
            button.keyboardShortcut(key, modifiers: modifiers)
        } else {
            button
        }
    }

    // MARK: Analysis read-out

    private var analysisCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    fieldLabel("ENGINE EVAL")
                    Spacer()
                    Toggle("", isOn: Binding(get: { game.evalEnabled },
                                             set: { game.setEvalEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(game.phase == .setup)
                }

                if game.phase == .setup {
                    Text("Available once game starts")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if game.evalEnabled {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Directional arrow — colour carries the Red/Black signal
                        if let s = game.evalRed, !game.isDrawShown {
                            let decisive = Engine.mate - Engine.maxDepth
                            if s < decisive && s > -decisive {
                                Image(systemName: s >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(s >= 0 ? Color(red:0.75,green:0.13,blue:0.11) : Color.primary)
                            }
                        }
                        Text(evalText)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.primary)   // always neutral — arrow carries the colour
                        if let a = game.analysis {
                            Text("depth \(a.depth)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Red’s view · piece value ≈ squares reached")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)

                    if let a = game.analysis, let best = a.best {
                        lineRow("Best", move: best, score: a.score)
                        if let second = a.secondBest {
                            lineRow("2nd", move: second, score: a.secondScore)
                        }
                    } else if game.winner == nil {
                        Text("analysing…").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("off").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var evalText: String {
        if game.isDrawShown { return "Draw" }
        guard game.evalEnabled, let s = game.evalRed else { return "–" }
        let decisive = Engine.mate - Engine.maxDepth
        if s >=  decisive { return "Red wins" }
        if s <= -decisive { return "Black wins" }
        return String(format: "%+.1f", Double(s) / 100.0)
    }

    private func lineRow(_ tag: String, move: Move, score: Int) -> some View {
        let isHighlighted = game.lineHighlight.map { $0.from == move.from && $0.to == move.to } ?? false
        return HStack(spacing: 6) {
            Text(tag)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Text(game.notation(for: move))
                .font(.system(size: 11, design: .monospaced))
            Spacer(minLength: 0)
            Text(scoreText(score))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture {
            let hl = (from: move.from, to: move.to)
            let same = game.lineHighlight.map { $0.from == move.from && $0.to == move.to } ?? false
            game.lineHighlight = same ? nil : hl
        }
    }

    private func scoreText(_ s: Int) -> String {
        let decisive = Engine.mate - Engine.maxDepth
        if s >=  decisive { return "#" }
        if s <= -decisive { return "-#" }
        return String(format: "%+.1f", Double(s) / 100.0)
    }

    // MARK: Game tab

    private var gameTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            analysisCard

            // Collapsible legend
            infoCard {
                DisclosureGroup(isExpanded: $legendExpanded) {
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
                        legendRow(color: Color(red: 1.0, green: 0.85, blue: 0.2).opacity(0.85),
                                  label: "Castle (\(game.liveBoard.castle.description))")
                        legendRow(color: Color(red: 0.86, green: 0.80, blue: 0.69), label: "Fort area")
                        legendRow(color: Color(red: 0.94, green: 0.90, blue: 0.81), label: "Castle zone")
                        legendRow(color: Color(red: 1.0, green: 0.85, blue: 0.30).opacity(0.45), label: "Last move")
                        legendRow(color: .green.opacity(0.45), label: "Valid move")
                        legendRow(color: .orange.opacity(0.75), label: "Can attack")
                        legendRow(color: Color.blue.opacity(0.25), label: "Engine line")
                    }
                    .padding(.top, 6)
                } label: {
                    Text("LEGEND")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            // Move list
            infoCard {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("MOVES")
                    if game.record.isEmpty {
                        Text("No moves yet")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 10)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(Array(game.record.enumerated()), id: \.element.id) { idx, entry in
                                        moveRow(idx: idx, entry: entry)
                                            .id(idx)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 150)
                            .onChange(of: game.viewIndex) { _ in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(game.viewIndex - 1, anchor: .center)
                                }
                            }
                        }
                    }

                    if let result = game.resultMessage {
                        Text(result)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(game.displayWinner == .red ? .red
                                             : (game.displayWinner == .black ? .primary : .secondary))
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func moveRow(idx: Int, entry: MoveRecord) -> some View {
        let isCurrent = idx == game.viewIndex - 1
        HStack(spacing: 6) {
            Text("\(idx + 1).")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            Text(entry.notation)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(entry.side == .red ? .red : .primary)
            if entry.reason != nil {
                Text("#").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            } else if game.drawPly == idx + 1 {
                Text("=").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1).padding(.horizontal, 4)
        .background(isCurrent ? Color.accentColor.opacity(0.22) : Color.clear)
        .cornerRadius(3)
        .contentShape(Rectangle())
        .onTapGesture { game.jumpTo(ply: idx + 1) }
    }

    // MARK: Rules tab

    private var rulesTab: some View {
        infoCard {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {

                    rulesSection("HOW TO WIN") {
                        """
                        1. Capture the opponent's King.
                        2. Move your King onto the Castle (centre square) and survive until it is your turn again.
                        3. Have at least one of your pieces in the opponent's fort while they have no pieces in their own fort.
                        """
                    }

                    rulesSection("MOVEMENT") {
                        """
                        • Most pieces slide in a straight line and cannot jump over another piece.
                        • The Axe and Hunter make a knight's leap. It is legal only if a straight line can be drawn from their square to the target without crossing an occupied square — and two pieces set corner-to-corner (diagonally) across the path also block the leap.
                        • Shieldwall: a one-step diagonal move is blocked when both squares beside it (orthogonally) are occupied.
                        • Capture by landing on an enemy piece, which is removed.
                        """
                    }

                    rulesSection("SKJOLDING  (V)") {
                        """
                        The footsoldier, and the most numerous piece. Advances two squares forward (the square just ahead must be clear), captures one square diagonally forward, and may step one square back. Diagonally placed Skjoldings guard one another — build chains for a strong line.
                        """
                    }

                    rulesSection("OFFICERS") {
                        """
                        K   King — one step in any direction. Reaches the Castle to win.
                        Sp  Spearman — wide reach ahead; narrow retreat.
                        Bw  Bowman — slides up to 4 forward; one step sideways.
                        Bk  Berserker — three forward lanes up to 3; one step sideways.
                        Sw  Sword — one step orthogonally, or a diagonal slide up to 4.
                        Wo  Wolf — orthogonal slide up to 3.
                        Ax  Axe — short orthogonal/diagonal step, plus a knight's leap.
                        Hu  Hunter — diagonal step, plus a knight's leap.
                        """
                    }

                    rulesSection("STRATEGY NOTES") {
                        """
                        • Minor pieces (Spearman, Bowman, Berserker) hold the centre and keep the enemy King from the Castle.
                        • Develop the Wolf and Hunter to the flanks first, the Sword and Axe behind them.
                        • The King's march to the Castle is a winning threat — but watch your own Fort.
                        • Material edge? Press both flanks at once — one must give.
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

    // MARK: Save / load panels

    private func saveGame() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "drott-game.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? game.exportGame().write(to: url, atomically: true, encoding: .utf8)
    }

    private func loadGame() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if !game.importGame(from: text) {
            game.statusMessage = "Couldn't read that game file."
        }
    }
}

// MARK: - Board

struct BoardView: View {
    @ObservedObject var game: GameState

    private var gridSize: CGFloat { SQ * CGFloat(game.boardN) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {

            // Row labels  N…1  (spacer at bottom matches eval-bar + column-label height)
            VStack(spacing: 0) {
                ForEach((0..<game.boardN).reversed(), id: \.self) { row in
                    Text("\(row + 1)")
                        .frame(width: 20, height: SQ)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
                Color.clear.frame(width: 20, height: 38)   // 4pt gap + 8pt bar + 26pt col labels
            }

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    grid
                    floatingPiece
                }
                .frame(width: gridSize, height: gridSize)
                .background(Color(red: 0.16, green: 0.16, blue: 0.18))
                .cornerRadius(4)

                // Horizontal eval bar below the grid
                EvalBar(redScore: game.evalRed, width: gridSize)
                    .padding(.top, 4)

                // Column labels  A…I / A…K
                HStack(spacing: 0) {
                    ForEach(0..<game.boardN, id: \.self) { col in
                        Text(String(UnicodeScalar(65 + col)!))
                            .frame(width: SQ, height: 26)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.45))
                    }
                }
            }
        }
    }

    private var grid: some View {
        let last = game.lastMove
        let board = game.viewedBoard
        let n = board.N
        let castlePos = board.castle
        let redFort = board.redFortSquares
        let blackFort = board.blackFortSquares
        let lineHL = game.lineHighlight
        return VStack(spacing: 0) {
            ForEach((0..<n).reversed(), id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<n, id: \.self) { col in
                        let pos = Position(col: col, row: row)
                        SquareView(
                            pos: pos,
                            piece: game.piece(at: pos),
                            isSelected:     game.selected == pos,
                            isMoveTarget:   game.highlightMoves.contains(pos),
                            isAttackTarget: game.highlightAttacks.contains(pos),
                            isDragOrigin:   game.dragOrigin == pos,
                            isLastMove:     last.map { $0.from == pos || $0.to == pos } ?? false,
                            isOnCastle:     pos == castlePos,
                            isInCastleZone: Position.isCastleZone(pos, N: n),
                            isOnFort:       redFort.contains(pos) || blackFort.contains(pos),
                            isLineHighlight: lineHL.map { $0.from == pos || $0.to == pos } ?? false
                        )
                        .onTapGesture { game.tap(pos) }
                        .gesture(
                            DragGesture(minimumDistance: 6, coordinateSpace: .local)
                                .onChanged { game.dragChanged(from: pos, translation: $0.translation) }
                                .onEnded   { game.dragEnded(from: pos, translation: $0.translation) }
                        )
                    }
                }
            }
        }
    }

    // The piece currently under the cursor, rendered above the grid so it can
    // float across squares while dragging.
    @ViewBuilder
    private var floatingPiece: some View {
        if let origin = game.dragOrigin, let p = game.draggedPiece {
            PieceToken(piece: p)
                .frame(width: SQ - 2, height: SQ - 2)
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
                .position(
                    x: CGFloat(origin.col) * SQ + SQ / 2 + game.dragTranslation.width,
                    y: CGFloat(game.boardN - 1 - origin.row) * SQ + SQ / 2 + game.dragTranslation.height
                )
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Evaluation bar
//
// Horizontal bar below the board: Red fills from the left, Black from the right.
// Red at 50 % = balanced; 100 % = decisive Red advantage.

struct EvalBar: View {
    let redScore: Int?      // Red perspective; positive = Red ahead
    let width: CGFloat

    private var decisive: Int { Engine.mate - Engine.maxDepth }

    private var fraction: CGFloat {
        guard let s = redScore else { return 0.5 }
        if s >=  decisive { return 1 }
        if s <= -decisive { return 0 }
        return CGFloat(1.0 / (1.0 + exp(-Double(s) / 150.0)))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color(red: 0.15, green: 0.15, blue: 0.18))           // Black (right)
            Rectangle().fill(Color(red: 0.78, green: 0.18, blue: 0.16))           // Red (left)
                .frame(width: max(0, min(width, width * fraction)))
        }
        .frame(width: width, height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.20), lineWidth: 0.5))
    }
}

// MARK: - Evaluation graph
//
// A chess-style game-evaluation chart. The midline is even; the silhouette
// rises into red where Red is ahead and falls into dark where Black is ahead.
// A marker shows the currently-viewed ply; tapping jumps to a ply.

struct EvalGraph: View {
    let scores: [Int?]          // Red perspective, one per ply (nil = pending)
    let current: Int            // viewIndex
    let onSelect: (Int) -> Void

    private let cap = 800.0      // ±8 "pawns" maps to the full half-height

    private func y(_ score: Int, _ h: CGFloat) -> CGFloat {
        let decisive = Double(Engine.mate - Engine.maxDepth)
        let s = Double(score)
        let clamped = s >= decisive ? cap : (s <= -decisive ? -cap : max(-cap, min(cap, s)))
        let mid = h / 2
        return mid - CGFloat(clamped / cap) * (mid - 2)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let n = max(scores.count, 1)
            let dx = n > 1 ? w / CGFloat(n - 1) : w

            ZStack(alignment: .topLeading) {
                Color(red: 0.16, green: 0.16, blue: 0.18)

                // Even-position midline.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h / 2))
                    p.addLine(to: CGPoint(x: w, y: h / 2))
                }.stroke(Color.white.opacity(0.25), lineWidth: 0.5)

                // Filled silhouette of the evaluation.
                if scores.contains(where: { $0 != nil }) {
                    silhouette(w: w, h: h, dx: dx)
                }

                // Current-ply marker.
                if current < n {
                    let x = CGFloat(current) * dx
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: h))
                    }.stroke(Color.yellow.opacity(0.9), lineWidth: 1.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let ply = Int((value.location.x / dx).rounded())
                        onSelect(max(0, min(n - 1, ply)))
                    }
            )
        }
    }

    // Build closed areas above/below the midline and fill each with its colour.
    @ViewBuilder
    private func silhouette(w: CGFloat, h: CGFloat, dx: CGFloat) -> some View {
        let mid = h / 2
        let pts: [CGPoint] = scores.enumerated().compactMap { i, s in
            s.map { CGPoint(x: CGFloat(i) * dx, y: y($0, h)) }
        }
        ZStack {
            // Red area (between curve and midline, clipped to the top half).
            areaPath(pts: pts, mid: mid)
                .fill(Color(red: 0.80, green: 0.20, blue: 0.18).opacity(0.85))
                .clipShape(Rectangle().path(in: CGRect(x: 0, y: 0, width: w, height: mid)))
            // Black area (bottom half).
            areaPath(pts: pts, mid: mid)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.06).opacity(0.85))
                .clipShape(Rectangle().path(in: CGRect(x: 0, y: mid, width: w, height: h - mid)))
            // The evaluation line itself.
            Path { p in
                guard let first = pts.first else { return }
                p.move(to: first)
                for pt in pts.dropFirst() { p.addLine(to: pt) }
            }.stroke(Color.white.opacity(0.7), lineWidth: 1)
        }
    }

    private func areaPath(pts: [CGPoint], mid: CGFloat) -> Path {
        Path { p in
            guard let first = pts.first, let last = pts.last else { return }
            p.move(to: CGPoint(x: first.x, y: mid))
            p.addLine(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
            p.addLine(to: CGPoint(x: last.x, y: mid))
            p.closeSubpath()
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
    var isDragOrigin: Bool = false
    var isLastMove: Bool = false
    var isOnCastle: Bool = false
    var isInCastleZone: Bool = false
    var isOnFort: Bool = false
    var isLineHighlight: Bool = false

    private static let normalBeige  = Color(red: 0.94, green: 0.90, blue: 0.81)
    private static let fortBeige    = Color(red: 0.86, green: 0.80, blue: 0.69)
    private static let castleGold   = Color(red: 1.0, green: 0.85, blue: 0.2).opacity(0.85)
    private static let textureBrown = Color(red: 0.35, green: 0.22, blue: 0.08)

    private var squareBase: Color {
        if isOnCastle { return Self.castleGold }
        if isOnFort   { return Self.fortBeige }
        return Self.normalBeige
    }

    var body: some View {
        ZStack {
            // Tile: rounded rect with shadow, 1px gap on each side
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(squareBase)

                // Castle zone: dot texture
                if isInCastleZone && !isOnCastle {
                    castleZoneDots
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // Fort: diagonal line texture
                if isOnFort {
                    fortDiagonals
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // Last move played (from & to squares): soft yellow wash.
                if isLastMove && !isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(red: 1.0, green: 0.85, blue: 0.30).opacity(0.45))
                }

                // Engine line highlight: soft blue tint.
                if isLineHighlight && !isSelected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.blue.opacity(0.22))
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

                // Piece or coordinate label. The dragged piece is hidden here —
                // a floating copy is rendered by the board instead.
                if let p = piece, !isDragOrigin {
                    PieceToken(piece: p)
                        .scaleEffect(isSelected ? 1.10 : 1.0)
                        .animation(.spring(response: 0.18, dampingFraction: 0.55), value: isSelected)
                } else if piece == nil && !isMoveTarget {
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
                             with: .color(Self.textureBrown.opacity(0.33)))
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
                           with: .color(Self.textureBrown.opacity(0.28)),
                           lineWidth: 0.8)
                offset += spacing
            }
        }
    }
}

// MARK: - Piece token

struct PieceToken: View {
    let piece: Piece

    // Red: deep carmine; Black: deep navy-slate.
    private var iconColor: NSColor {
        piece.side == .red
            ? NSColor(red: 0.75, green: 0.11, blue: 0.09, alpha: 1)
            : NSColor(red: 0.10, green: 0.11, blue: 0.22, alpha: 1)
    }
    private var circleColor: Color {
        piece.side == .red
            ? Color(red: 1.00, green: 0.97, blue: 0.96)
            : Color(red: 0.96, green: 0.96, blue: 0.99)
    }

    private var nsImage: NSImage? {
        let name = piece.type.rawValue   // "wolf", "king", "skjolding", etc.
        func load(from url: URL) -> NSImage? {
            guard let raw = NSImage(contentsOf: url) else { return nil }
            // Paint the silhouette with the side colour using sourceAtop compositing.
            let size = raw.size
            let tinted = NSImage(size: size, flipped: false) { rect in
                raw.draw(in: rect)
                self.iconColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            return tinted
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "svg") {
            if let img = load(from: url) { return img }
        }
        if let resURL = Bundle.main.resourceURL {
            let url = resURL
                .appendingPathComponent("Drott_Drott.bundle")
                .appendingPathComponent("\(name).svg")
            if let img = load(from: url) { return img }
        }
        return nil
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(circleColor)
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
