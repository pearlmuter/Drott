import Foundation
import CoreML

// MARK: - Astrid: the neural (AlphaZero) engine
//
// Runs a CoreML policy/value net (exported from the trained PyTorch model — see
// python/export_coreml.py) under a native MCTS over the existing `Board`. The
// encoding mirrors, square-for-square, the parity-proven Python adapter
// (python/drott_game.py + drott_nnet.py): an 18-plane board from the side-to-move's
// point of view, and a 6561-wide from×to action space. Drott positions can cycle
// (kings shuffling), so the search is depth-capped exactly like capped_mcts.py.
//
// The net only ever sees the canonical board (the mover as +code, moving "up"),
// so for Black the board is rotated 180° + side-swapped when building planes, and
// action indices are rotated 180° when reading priors. Everything that decides
// legality or terminal state comes straight from `Board`, which is already proven
// identical to the rules the net trained against.

enum NeuralEngine {

    static let planeCount = 18          // 9 piece types × 2 sides
    static let actionSize = 6561        // 81 from-squares × 81 to-squares
    private static let cpuct: Float = 1.0
    private static let maxDepth = 120   // per-descent cap; breaks cycles

    // MARK: Model discovery & loading

    /// Resource base-names of every bundled model in `models/` (e.g. "Astrid_v0").
    /// Drop a new `.mlpackage` into `Sources/Drott/models/`, rebuild, and it
    /// appears here automatically — no code or Package.swift change needed.
    static func availableModels() -> [String] {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "mlpackage",
                                             subdirectory: "models") else { return [] }
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// "Astrid_v0" → "Astrid v0" for display.
    static func displayName(_ resource: String) -> String {
        resource.replacingOccurrences(of: "_", with: " ")
    }

    private static var cache: [String: MLModel] = [:]
    private static let cacheLock = NSLock()

    private static func model(named name: String) -> MLModel? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let m = cache[name] { return m }
        guard let url = Bundle.module.url(forResource: name, withExtension: "mlpackage",
                                          subdirectory: "models") else {
            return nil
        }
        do {
            let compiled = try MLModel.compileModel(at: url)
            let m = try MLModel(contentsOf: compiled)
            cache[name] = m
            return m
        } catch {
            FileHandle.standardError.write(Data("NeuralEngine: failed to load \(name): \(error)\n".utf8))
            return nil
        }
    }

    // MARK: Encoding (mirrors drott_game.py / drott_nnet.py)

    /// Flat from×to action index for a move, real (absolute) frame.
    private static func realAction(_ from: Position, _ to: Position) -> Int {
        let f = from.col + from.row * 9
        let t = to.col + to.row * 9
        return f * 81 + t
    }

    /// The policy is in the mover's canonical frame. For Red that equals the real
    /// frame; for Black it is the 180° rotation (square idx → 80 − idx).
    private static func canonicalAction(_ realIdx: Int, _ side: Side) -> Int {
        if side == .red { return realIdx }
        let f = realIdx / 81, t = realIdx % 81
        return (80 - f) * 81 + (80 - t)
    }

    /// Fill an 18×9×9 plane buffer from `board`, from `side`'s point of view:
    /// the mover's pieces in planes 0…8, the opponent's in 9…17, rotated 180° for
    /// Black so the mover always "moves up". `ptr` must hold 18*81 floats, zeroed.
    private static func fillPlanes(_ board: Board, _ side: Side, into ptr: UnsafeMutablePointer<Float>) {
        for sq in board.squares {
            guard let p = sq else { continue }
            let mine = p.side == side
            let plane = (mine ? 0 : 9) + Int(p.type.code) - 1
            let r = side == .red ? p.pos.row : 8 - p.pos.row
            let c = side == .red ? p.pos.col : 8 - p.pos.col
            ptr[(plane * 9 + r) * 9 + c] = 1
        }
    }

    /// Run the net on `board` from the side-to-move's POV.
    /// Returns (policy over 6561 canonical actions, value in [-1,1] for the mover).
    private static func predict(_ board: Board, _ model: MLModel) -> (policy: [Float], value: Float)? {
        guard let input = try? MLMultiArray(shape: [1, 18, 9, 9], dataType: .float32) else { return nil }
        let inPtr = input.dataPointer.bindMemory(to: Float.self, capacity: planeCount * 81)
        inPtr.update(repeating: 0, count: planeCount * 81)
        fillPlanes(board, board.sideToMove, into: inPtr)

        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: ["planes": MLFeatureValue(multiArray: input)]),
              let out = try? model.prediction(from: provider),
              let pol = out.featureValue(for: "policy")?.multiArrayValue,
              let val = out.featureValue(for: "value")?.multiArrayValue
        else { return nil }

        var policy = [Float](repeating: 0, count: actionSize)
        let polPtr = pol.dataPointer.bindMemory(to: Float.self, capacity: actionSize)
        for i in 0..<actionSize { policy[i] = polPtr[i] }
        let value = val.dataPointer.bindMemory(to: Float.self, capacity: 1)[0]
        return (policy, value)
    }

    // MARK: MCTS

    private struct Edge: Hashable { let s: UInt64; let a: Int }

    private final class Context {
        let model: MLModel
        var Qsa: [Edge: Float] = [:]
        var Nsa: [Edge: Int] = [:]
        var Ns:  [UInt64: Int] = [:]
        var Ps:  [UInt64: [Float]] = [:]   // priors aligned with Vs[s]
        var Vs:  [UInt64: [Move]] = [:]
        init(_ model: MLModel) { self.model = model }

        /// One MCTS descent. Returns the value to back up to the parent (negamax).
        func search(_ board: Board, _ depth: Int) -> Float {
            if depth >= maxDepth { return 0 }

            // Terminal: the win timing is already baked into Board by `applying`.
            if let w = board.winner {
                let vSelf: Float = (w == board.sideToMove) ? 1 : -1
                return -vSelf
            }

            let s = board.repetitionKey

            if Ps[s] == nil {                                   // leaf — expand
                let valids = board.legalMoves()
                if valids.isEmpty { return 1 }                  // stuck side loses (-1) → -(-1)
                guard let (policy, value) = predict(board, model) else { return 0 }
                let side = board.sideToMove
                var priors = [Float](repeating: 0, count: valids.count)
                var sum: Float = 0
                for (i, mv) in valids.enumerated() {
                    let p = policy[canonicalAction(realAction(mv.from, mv.to), side)]
                    priors[i] = p; sum += p
                }
                if sum > 0 { for i in priors.indices { priors[i] /= sum } }
                else { for i in priors.indices { priors[i] = 1 / Float(valids.count) } }
                Ps[s] = priors
                Vs[s] = valids
                Ns[s] = 0
                return -value
            }

            // Internal node — pick the max-PUCT legal move.
            let valids = Vs[s]!, priors = Ps[s]!
            let nS = Float(Ns[s] ?? 0)
            var bestU = -Float.infinity
            var bestI = 0
            for (i, mv) in valids.enumerated() {
                let a = realAction(mv.from, mv.to)
                let edge = Edge(s: s, a: a)
                let u: Float
                if let q = Qsa[edge] {
                    u = q + cpuct * priors[i] * (nS.squareRoot()) / Float(1 + (Nsa[edge] ?? 0))
                } else {
                    u = cpuct * priors[i] * (nS + 1e-8).squareRoot()
                }
                if u > bestU { bestU = u; bestI = i }
            }

            let mv = valids[bestI]
            let a = realAction(mv.from, mv.to)
            let edge = Edge(s: s, a: a)
            let child = board.applying(mv)
            let v = search(child, depth + 1)

            if let q = Qsa[edge] {
                let n = Nsa[edge] ?? 0
                Qsa[edge] = (Float(n) * q + v) / Float(n + 1)
                Nsa[edge] = n + 1
            } else {
                Qsa[edge] = v
                Nsa[edge] = 1
            }
            Ns[s] = (Ns[s] ?? 0) + 1
            return -v
        }

        /// Visit count of the root edge for `mv`.
        func rootVisits(_ rootKey: UInt64, _ mv: Move) -> Int {
            Nsa[Edge(s: rootKey, a: NeuralEngine.realAction(mv.from, mv.to))] ?? 0
        }
    }

    // MARK: Public API

    /// Astrid's move: run `iterations` MCTS simulations and return the
    /// most-visited root move. Always a legal move (or nil if the model is
    /// missing / the position has no moves). Safe to call off the main thread.
    static func bestMove(for board: Board, history: [Board] = [],
                         modelName: String, iterations: Int) -> Move? {
        guard board.winner == nil else { return nil }
        let legal = board.legalMoves()
        guard !legal.isEmpty else { return nil }
        guard let model = model(named: modelName) else { return nil }

        let ctx = Context(model)
        let rootKey = board.repetitionKey
        for _ in 0..<max(1, iterations) { _ = ctx.search(board, 0) }

        // Most-visited root move; ties and zero-visit fallbacks resolve to the
        // highest prior, then to the first legal move — never an illegal one.
        var best = legal[0]
        var bestVisits = -1
        for mv in legal {
            let v = ctx.rootVisits(rootKey, mv)
            if v > bestVisits { bestVisits = v; best = mv }
        }
        return best
    }
}
