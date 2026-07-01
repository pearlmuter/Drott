# Herringbone → Halibut: making the classical engine stronger

Goal: a meaningfully stronger classical Drott engine. We build a new variant
**Halibut** (namespace `D.HB`), keep **Herringbone** (`D.HR`) untouched as the
baseline, and prove Halibut is stronger by playing them head-to-head in a match
harness. Every change is judged by that harness — we keep only what wins.

Motivation: an 8-year-old beat "Medium" on the first try. That is not a medium.

---

## Diagnosis (measured, not guessed)

Benchmark of `herringbone-ai.js` from the start position:

| Time         | Depth reached | move-gen calls |
|--------------|---------------|----------------|
| 2s  (Easy)   | 7             | 274k           |
| 5s  (Normal) | 8             | 649k           |
| 10s (Hard)   | 9             | 1.3M           |

Throughput ≈ **130k move-gen calls/sec** — low. Root causes:

1. **SEE re-generates all moves.** `staticExchangeEval` and `cheapestAttacker`
   (herringbone-ai.js:135, :150) call full `D.legalMoves()` for a side, and they
   run for *every capture* during move ordering (orderKey :199) and in
   quiescence. Move ordering is supposed to be cheap; here it triggers repeated
   full move generation. This throttles depth more than anything else.

2. **No king-safety term.** `BASE_VALUE.king = 0` and `evaluate()` has no term for
   the king being threatened. Exchanges already treat the king as worth 10000
   (`SEE_VALUE.king`), so direct captures are handled — but the engine has no
   *positional* sense that its king is getting into danger until the search
   literally reaches the capture ply.

3. **Difficulty is only think-time.** Easy/Normal/Hard = 2/5/10s. The engine plays
   essentially the same; only depth differs slightly. Nothing makes "Medium" a
   distinct, deliberately-weaker strength.

The weakness is a mix of **speed** (caps depth), an **eval blind spot** (king
safety), and **flat difficulty calibration** — not one single bug.

---

## Design principles (from review)

- **Stochasticity only at the endpoint, never in the search.** The tree search
  stays 100% deterministic. Randomness lives *only* in the final root move-pick
  (`pickMove`), where a weaker level may choose among the best 2–3 moves. This is
  already how the code is structured — the search has no `Math.random`; only
  `pickMove` does. We keep it that way and make variety scale with difficulty:
  - **Strongest level:** deterministic — always the single best move.
  - **Weaker levels:** pick uniformly among moves within a margin of the best
    (the existing `VARIETY_MARGIN`/`hangsMovedPiece` machinery), so they stay
    reasonable but not perfect.
  - No eval noise is ever injected into the search itself.

- **King gets a real material value.** Give the king a modest base value (~100,
  same order as a Skjolding) in the eval, *and* add a king-safety term. The base
  value is a cheap tweak; the safety term is the substantive fix. Both are tested
  through the harness before we keep them.

- **Herringbone is the frozen baseline.** All work lands in Halibut. Herringbone
  never changes, so the match result is always a clean A/B.

---

## Phase 0 — Measuring stick (do first, no engine changes)

- **Match harness** (`drott-electron/tools/match.js`, headless Node): Engine A vs
  Engine B for N games, alternating colors, with a few opening deviations so games
  aren't identical. Reports W/L/D and a confidence margin. Classical-engine
  analogue of Astrid's arena. Every later change is judged here.
- **Throughput/perft bench** — track nodes/sec per change (working prototype
  already exists).
- **Reproduce the loss** — wire dumb opponents (random, greedy-capture) and a
  shallow fixed-depth Herringbone; capture a few games to find concrete blunders
  and confirm the root cause before building.

## Phase 1 — Halibut scaffold

- Copy `herringbone-ai.js` → `halibut-ai.js`, namespace `D.HB`; own fork +
  dispatch wiring. Herringbone stays byte-for-byte as the baseline.

## Phase 2 — Speed (unlocks depth; likely the biggest single win)

- Replace `legalMoves`-based SEE/attacker lookup with a **direct attacker scan**
  (walk piece deltas into the target square instead of generating all moves).
- **Staged move generation**: try TT/killer/capture moves before generating
  quiets, so beta cutoffs skip quiet generation entirely.
- Target: 3–10× throughput → +1 to +3 plies at the same time budget.

## Phase 3 — Search (standard high-Elo techniques)

- **Null-move pruning** — one of the biggest single gains in alpha-beta engines.
- Depth-scaled **LMR** (currently a flat 1-ply reduction at :375).
- **Win-condition extensions** — extend when a king is near the castle or a piece
  has entered the enemy fort (Drott-specific threats the generic search
  under-weights).

## Phase 4 — Evaluation

- **King base value ~100** + a **king-safety term** (enemy attackers near the
  king, available escape squares).
- Threat awareness for all three win conditions (king→castle race, fort incursion,
  king capture).
- **Tune weights against the harness** — accept a weight change only if it wins a
  match. Same accept/reject discipline as Astrid.

## Phase 5 — Difficulty calibration (the actual fix for "Medium is too easy")

Difficulty comes from **search budget + endpoint variety only — never search
noise**:

- **Strength via depth/time caps** — Easy/Normal are given shallower search
  (depth cap and/or shorter time), Hard gets the full-strength Halibut search.
- **Endpoint variety scales down with strength** — Easy picks among more
  near-best moves (wider margin), Normal fewer, Hard is deterministic best-move.
- The search kernel is identical and deterministic at every level; only the depth
  budget and the size of the root-move pool change.

## Phase 6 — Integration

- Add Halibut to the engine dropdown; recalibrate the three levels; update tests
  and rules/help text.

---

## Open decisions (to settle before/while building)

1. **Coexist or replace?** Keep Herringbone selectable as an easier classical AI
   alongside Halibut, or have Halibut become *the* classical engine and retire the
   Herringbone name in the UI?
2. **How strong should "Hard" be?** Genuinely tough for a club-level adult, or a
   friendly "beatable with effort" for a broad audience? Sets how aggressive we
   get in Phases 2–4.

## Recommended first cut

Do **Phase 0 + Phase 2** only, measure the depth/strength jump against the
harness, then decide how far to push. If the speed fix alone makes Halibut beat
Herringbone convincingly, we may not need every technique below it.

---

## Testing discipline

- Equal time control, many games, colors alternated; require a statistically
  meaningful win margin before "accepting" a change (SPRT-style).
- Test changes in isolation so we know what actually helped.
- Herringbone remains the frozen reference opponent throughout.

## Results (measured)

Match harness (`drott-electron/tools/match.js`), colors alternated, deterministic
best-move play, random 3-ply openings. Feature isolation vs frozen Herringbone at
equal depth 4 (40 games each):

| Feature (alone)        | Score vs HR | Verdict            |
|------------------------|-------------|--------------------|
| all flags off (sanity) | 50.0%       | HB ≡ HR ✓          |
| light move ordering    | ~neutral, ~30% faster | keep     |
| scaled LMR             | neutral, faster | keep           |
| king-safety eval       | **HB +44 Elo** | keep            |
| null-move pruning      | **HB −35 Elo** | drop (unsound: king-capture game, no "check") |
| win-condition ext.     | crashed (non-terminating) | removed |

Combined Halibut (light ordering + scaled LMR + king safety; null-move off):

- **Equal depth: HB +56 Elo** (58% over 50 games) — better per node.
- **Equal time (0.25s/move): HB +98 Elo** (63.7% over 40 games) — per-node
  quality plus ~30% higher throughput cashed in as extra depth.

Difficulty (endpoint variety only; search always deterministic): Easy = depth-cap
4 + variety 60; Normal = full time + variety 15; Hard = full time + variety 0.

### Discovered (separate, pre-existing) — king diagonal rule divergence

While re-enabling the dormant parity test (its corpus path was wrong), it surfaced
that the shipped JS `_king` generator (drott-rules.js) blocks diagonal king moves
with a shield-wall corner-pinch, but the canonical Python `_king`
(python/drott_rules.py:362) — the rules **Astrid was trained on** — emits all 8
king moves unconditionally. JS is over-restrictive for the king. This is
pre-existing, affects HR and HB equally, and is a gameplay-rules change, so it was
left untouched pending a decision (fix JS to match canonical + re-enable parity, or
confirm the block is intended and regenerate the corpus).

## References

- Null Move Pruning — https://www.chessprogramming.org/Null_Move_Pruning
- Move Ordering — https://www.chessprogramming.org/Move_Ordering
- Static Exchange Evaluation — https://www.chessprogramming.org/Static_Exchange_Evaluation
- Playing strength progression (Rustic) — https://rustic-chess.org/progress/playing_strength.html
