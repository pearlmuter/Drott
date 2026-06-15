# Drott × AlphaZero — Long-Term Engine Plan

*Living document. Author: Claude (with Emil). Last updated: 2026-06-15.*

The goal: replace/augment Drott's hand-written minimax engine with a learned
AlphaZero-style engine, trained on this Mac in interruptible nightly sessions,
producing a ladder of opponents from beginner to ~1400 Elo.

Framework: [suragnair/alpha-zero-general](https://github.com/suragnair/alpha-zero-general).

---

## 0. How we'll work together

- **This file is the source of truth.** Every phase below has a checkbox.
  We update it as we go. When a decision is made, we record it in the
  "Decisions log" at the bottom so we never re-litigate it.
- **I (Claude) do:** the code — Python rules port, the alpha-zero-general glue,
  the export pipeline, the Swift-side MCTS, the parity harness, scripts.
- **You (Emil) do:** the things only you can — installing Python/PyTorch,
  running the actual overnight training, eyeballing whether the AI "plays like
  Drott," telling me when a rule feels wrong, and the go/no-go calls at each
  milestone.
- **I will communicate at every milestone**: what I built, how to run it, what I
  expect to see, and what could go wrong. If I'm blocked on a decision that's
  genuinely yours, I'll stop and ask rather than guess.

---

## 1. What AlphaZero-general needs from us

The framework is game-agnostic. To plug Drott in we implement **one Python class**
(`Game`) plus **one neural-net wrapper**. Everything else (self-play loop, MCTS,
training, model-vs-model arena) is reused as-is.

### 1.1 The `Game` interface (the contract we must satisfy)

| Method | Contract | Drott mapping |
|---|---|---|
| `getInitBoard()` | starting board (numpy array) | 9×9 start position encoded as planes (§2.1) |
| `getBoardSize()` | `(x, y)` | `(9, 9)` |
| `getActionSize()` | total #actions | `81 × 81 = 6561` (from-square × to-square, §2.2) |
| `getNextState(board, player, action)` | `(nextBoard, -player)` | decode action → `Board.applying(move)` |
| `getValidMoves(board, player)` | binary vector len=actionSize | mask from `Board.legalMoves()` |
| `getGameEnded(board, player)` | `0` ongoing / `+1` win / `-1` loss / small ε draw | king-capture, castle, fort, repetition |
| `getCanonicalForm(board, player)` | board from current player's POV | identity for red; 180° rotate + side-swap for black (§2.3) |
| `getSymmetries(board, pi)` | list of `(board, pi)` equivalents | identity + left-right mirror (§2.4) |
| `stringRepresentation(board)` | hashable string for MCTS | reuse the existing Zobrist-style hash, as bytes |

### 1.2 The `NeuralNet` wrapper

A PyTorch module (`pytorch/NNet.py` style): conv tower → two heads (policy logits
over 6561 actions, scalar value in [-1, 1]). We start by **copying the Othello
example** (`othello/pytorch/`) and adjusting input channels, board size, and
action size. Othello is the canonical reference implementation in this repo.

---

## 2. The hard part: encoding Drott for a neural net

This is where all the design risk lives. Three things must be exactly right:
board encoding, action encoding, and canonical form.

### 2.1 Board tensor (input planes)

Drott has **9 piece types × 2 sides**. We cannot use the ±1 single-plane trick
that Othello uses. Plan: a stack of binary 9×9 planes.

- 9 planes: current player's pieces (one per type).
- 9 planes: opponent's pieces (one per type).
- (optional, later) 1–2 constant planes for board features the net can't infer:
  fort squares, castle zone. Likely unnecessary since they're fixed, but cheap
  insurance.

→ Input shape `(18, 9, 9)` to start. Canonical form (§2.3) guarantees the
"current player" is always planes 0–8, so the net only ever learns one
perspective.

### 2.2 Action encoding — **from×to flat space (6561)**

Every Drott move is fully described by `(from, to)` — there are no promotions or
multi-step special moves to encode. So:

```
action = from_index * 81 + to_index     # from_index, to_index ∈ [0, 80]
```

- Pros: dead simple, impossible to get subtly wrong, trivially reversible.
- Cons: 6561 outputs, ~98% always-illegal. This is fine — `getValidMoves`
  masks them every step, exactly as Othello masks its board²+1 space. The net
  learns to ignore the dead entries quickly.
- A compact "move-plane" encoding (à la AlphaZero-chess, ~73 planes) would
  shrink the head but is far more error-prone given Drott's mixed movement
  (knight leaps, diagonal-2, forward-slides). **Deferred** as a possible
  optimization only if the 6561 head proves too slow/large (it won't, for 9×9).

### 2.3 Canonical form — the symmetry that makes training tractable

Drott's start position is **point-symmetric**: black is red rotated 180°
(`col→8-col, row→8-row`). I verified the forts map onto each other under this
rotation and the castle is the fixed center. Forward-moving pieces (pawn,
bowman, spearman) flip direction under 180°, which is exactly correct (red moves
"up", black moves "down").

→ `getCanonicalForm(board, black)` = rotate the board 180° **and** swap piece
ownership. After this, the network always sees "my pieces, moving up the board,"
halving what it must learn. Action vectors get the same 180° remap.

### 2.4 Symmetries for data augmentation

I verified both forts and the castle zone are **left-right symmetric**
(`col→8-col`), and no piece has left/right-biased movement. So horizontal mirror
is a valid game symmetry → free 2× training data via `getSymmetries`
(identity + h-mirror, with `pi` remapped accordingly).

- We will **start with identity-only** (always correct, zero risk) and switch on
  the h-mirror once the parity harness (§4) confirms the remap is bug-free.
- Vertical mirror is *not* a standalone symmetry (it flips forward-pieces) — skip.

---

## 3. Architecture: where the engine actually runs

Two distinct phases with different needs:

```
   TRAINING (Python, this Mac, nightly)          PLAY (shipped Swift app)
   ┌─────────────────────────────┐               ┌──────────────────────────┐
   │ DrottGame.py  (rules port)  │   export      │ CoreML model  (per ckpt) │
   │ alpha-zero-general Coach/   │  ──────────▶  │ Swift-native MCTS        │
   │ MCTS/NNet  (PyTorch+MPS)    │   CoreML      │ existing Board engine    │
   │ → checkpoint_N.pth.tar      │               │ → picks a move           │
   └─────────────────────────────┘               └──────────────────────────┘
```

- **Training in Python.** Apple-Silicon PyTorch uses the **MPS** backend for GPU
  acceleration (fallback CPU). alpha-zero-general runs unmodified once
  `DrottGame.py` exists.
- **Play in Swift via CoreML.** We export each chosen checkpoint to CoreML and
  run a **native Swift MCTS** that calls it. The shipped app needs *no* Python.
  The existing `Board` value type already gives us `legalMoves()`,
  `applying()`, and `winner` — everything MCTS needs. The new engine slots in
  beside the current minimax `Engine` (we can A/B them).
- **Dev-time shortcut.** Before the CoreML path exists, a tiny local Python
  socket/HTTP server can serve net evaluations to the Swift app for end-to-end
  testing. Throwaway scaffolding; not shipped.

### 3.1 The #1 risk: rule parity between Swift and Python

If the Python rules differ from the Swift rules *at all*, the trained net is
worthless in the app. We neutralize this with a **golden oracle**:

1. Extend the Swift `SelfTest` to dump a JSON corpus: many positions, each with
   `{board, sideToMove, legalMoves[], (move → resultingBoard, winner)}` —
   including tactical edge cases (knight blocking, fort claims, captures).
2. The Python port loads this corpus and must reproduce **every** legal-move set
   and every transition exactly. CI-style: any mismatch fails loudly.
3. Drott's existing 48 self-tests are the seed for these cases.

This makes the Python port *provably* faithful before we waste a single GPU-hour.

---

## 4. The "opponents of all skill levels" + Elo ~1400 target

This falls out of the training process almost for free:

- alpha-zero-general saves `checkpoint_<iter>.pth.tar` after every iteration.
  Early checkpoints are weak, late ones strong → **the checkpoint sequence *is*
  the difficulty ladder.**
- We anchor Elo with an **Arena ladder**: round-robin games among (a) selected
  checkpoints and (b) the existing minimax `Engine` at depths 1…N (known, cheap
  reference points). From the win/loss matrix we fit Elo ratings.
- "1400" is meaningful only against a defined pool — we'll define the pool as
  {minimax depths + human play}. We pick the checkpoint nearest each target
  difficulty for the in-app opponent selector.

Honest expectation: training a from-scratch AZ agent to a modest target on one
Mac is **weeks of wall-clock**, which is exactly why it's nightly. 1400 (decent
club-player, not superhuman) is realistic for 9×9; we are not chasing perfection.

---

## 5. Interruptible nightly training

alpha-zero-general already checkpoints at **iteration** granularity (saves the
net + the `.examples` replay buffer, resumes with `skipFirstSelfPlay`). We add:

- A **wrapper script** (`train_nightly.py`) that:
  - traps `SIGINT`/`SIGTERM`, finishes the current *episode*, flushes examples,
    saves, and exits 0 — so "stop in the morning" never corrupts state;
  - is sized so one iteration comfortably fits one night (tune `numEps` /
    `numMCTSSims`);
  - writes a `progress.json` (iteration, episode, timestamp, latest Elo).
- A **launchd plist** (macOS) to start it at night and a clean stop signal in
  the morning — or just a documented manual `Ctrl-C` if you'd rather drive it.
- Snapshots are never deleted automatically → the full skill ladder is preserved.

---

## 6. Phased roadmap (checkable)

Each phase ends with something you can see/run. We don't start a phase until the
previous one's exit criterion is met.

### Phase 0 — Foundations & decisions  🟦 (nearly done)
- [x] Board size decided: **9×9 only** (the 11×11 variant was removed from the game).
- [x] You: Python 3.11.4 + PyTorch 2.12 installed; `torch.backends.mps.is_available()` → **True**.
- [x] I: scaffolded `python/` with pinned `requirements.txt` + README.
- [ ] You: clone alpha-zero-general locally; train the Othello example 1 iteration
      (the last Phase-0 smoke test). *Remaining open decisions (Elo pool, training
      driver, distribution) don't block Phase 1–2 and can wait until Phase 4.*

### Phase 1 — Rules port + parity oracle  ✅ COMPLETE (2026-06-15)  ← *the critical phase*
- [x] Swift `Corpus.swift` emits the JSON golden corpus on `DROTT_DUMP_CORPUS=1`
      (start, single-piece-per-square sweep, 80 seeded random self-play games,
      curated win-timing/shieldwall/pinch positions).
- [x] `python/drott_rules.py` — faithful, dependency-free port of `Models.swift`.
- [x] `python/test_parity.py` — checks hash, legal-move set, and every transition.
- **Exit MET:** parity **green on 9,498 positions / 371,194 transitions**, including
  42k captures, 1,964 king-captures, 90 castle wins, 1,205 fort wins. Python
  matches Swift 100%. The rule-drift gate is closed; NN work may begin.

### Phase 2 — Game adapter + sanity training  🟦 (in progress, 2026-06-15)
- [x] `python/drott_game.py` — alpha-zero-general `Game` over `drott_rules.py`:
      9×9 signed-int grid, 6561 from×to actions, canonical = 180°+swap, action
      180°-remap in `getNextState` for player −1, static `getGameEnded`, identity
      symmetries. **Proven in lockstep with the rules** (`test_game.py`: 300 games
      / 31,133 plies, start hash matches Swift, all terminals agree).
- [x] `python/drott_nnet.py` — `DrottNNet` (conv tower → policy[6561] + value),
      18-plane input, runs on MPS or CPU. `python/capped_mcts.py` — depth-capped
      MCTS (Drott positions cycle; the stock unbounded `MCTS.search` recurses
      forever on a repeat). `python/train_drott.py` — self-contained ply-capped
      self-play trainer + eval-vs-random (stock Coach/Arena are uncapped → would
      hang). Pipeline runs end to end; policy loss decreases.
- [ ] Reach trained-net-vs-random ≫ 50% — needs a longer run than a quick smoke
      (pure-Python MCTS on one Mac is slow). The mechanism is proven; this is just
      compute. Discovered gotcha: **stalemate/cycle handling** — Drott needs a
      move-clock or cap so games terminate (the trainer caps at `--maxmoves`).
- **Exit:** trained-net-vs-random win rate ≫ 50%; loss curves sane.

> **Key finding (2026-06-15):** the canonical form rotates the board (unlike
> Othello's colour-only flip), so the canonical-frame action must be rotated 180°
> back inside `getNextState` when the real player is Black (Coach/Arena sample the
> action in canonical space but apply it on the real board). Inside MCTS the
> player is always 1, so no remap there. Proven correct by the lockstep test.

### Phase 3 — Inference bridge into Swift  ⬜
- [ ] I: CoreML export script (PyTorch → CoreML), verified to match PyTorch
      outputs on sample boards (numerical parity).
- [ ] I: native Swift MCTS + `NeuralEngine` using the CoreML model, beside the
      existing `Engine`; a settings toggle to choose engine.
- **Exit:** the app plays a full legal game driven by an exported (even weak) net.

### Phase 4 — Real training + Elo ladder  ⬜
- [ ] I: `train_nightly.py`, launchd plist, `progress.json`, Arena-Elo script.
- [ ] You: run nightly training; we track Elo over iterations together.
- [ ] I: in-app opponent selector mapped to checkpoint Elos.
- **Exit:** a strongest checkpoint at/near 1400 vs. the defined pool, plus a
  spread of weaker opponents selectable in the UI.

### Phase 5 — Polish  ⬜
- [ ] Tune net size/sims for play-time latency; trim the checkpoint set we ship.

*(The 11×11 variant was removed from the game — 9×9 is the only board size, so
there is no second-board-size phase.)*

---

## 7. Risks & mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Swift/Python rule drift | **Critical** | Golden-oracle parity harness (§3.1) before any training |
| Training too slow on one Mac | High | MPS backend; modest target; small net; tune sims/eps; nightly cadence |
| Canonical/symmetry remap bugs | High | Start identity-only; enable h-mirror only after parity proof |
| CoreML ≠ PyTorch numerically | Medium | Output-parity check in the export step (Phase 3 exit) |
| Action space 6561 too big/slow | Low | Confirmed fine for 9×9; move-plane encoding held in reserve |
| "1400 Elo" undefined | Medium | Fix the Elo pool (minimax depths + human) up front (§8) |
| Interrupt corrupts state | Medium | Signal-trapped wrapper finishes the episode, then saves |

---

## 8. Open decisions (need your input before/at Phase 0)

1. **Board size for v1.** Recommend **9×9 only** first (default, smaller action
   space, faster training); add 11×11 later as Phase 5. OK?
2. **Elo reference pool.** Recommend anchoring Elo against the **existing minimax
   engine at fixed depths + your own games**. Any other anchor you want?
3. **Training driver.** Fully automated **launchd nightly**, or **manual
   start/Ctrl-C** that you run when you want? (We can do manual first, automate
   later.)
4. **Distribution.** Is the end state a self-contained app for *you* only, or
   something you intend to share? (Affects whether we must avoid any Python at
   play time — current plan already does, via CoreML.)

---

## 9. Decisions log

*(append-only; date + decision)*

- 2026-06-15 — Plan drafted. Action encoding = from×to (6561). Training in
  Python/PyTorch-MPS; play in Swift via CoreML + native MCTS. Parity oracle is
  the gate before training. Canonical form = 180°+side-swap; augmentation =
  LR-mirror (deferred until parity-proven).
