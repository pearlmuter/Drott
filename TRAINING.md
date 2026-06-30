# Training Astrid — best practices

All commands run from the **repo root** (`Drott/`) unless noted.

---

## The right script for nightly runs: `launch_training.sh`

`train.sh` is a quick dev/smoke shortcut. For real nightly training use
`launch_training.sh` — it runs in the background with nohup, adds caffeinate
(prevents Mac sleep), logs to `python/temp/training.log`, and stops cleanly at
06:00.

```bash
cd python && bash launch_training.sh
```

Watch progress:

```bash
tail -f python/temp/training.log
```

Stop cleanly at any time (finishes the current iteration, saves, exits):

```bash
kill -INT $(cat python/temp/training.pid)
```

Never kill with `-9` — that corrupts the replay buffer.

---

## Hard rules — do not deviate from these

### 1. Always `--device cpu`. Never `--device mps`.

MPS is confirmed **slower** for this workload. The net is called once per tree
expansion (batch size = 1); MPS has high per-call overhead that dominates. One
experiment: MPS completed 1 iteration in 3 hours vs several on CPU. The comment
in `drott_nnet.py` is correct. Do not override it.

### 2. Always `--resume` when continuing an existing run.

Without `--resume`, training starts from a randomly initialised network and the
replay buffer is empty — all previous training is discarded. `launch_training.sh`
already includes it. If you invoke `train_drott.py` directly, always add it:

```bash
cd python && python3 train_drott.py --resume ...
```

### 3. Never interrupt mid-iteration with Ctrl-C repeatedly / kill -9.

One clean `kill -INT <pid>` (or Ctrl-C once) causes the trainer to finish the
current episode, flush the replay buffer, save the checkpoint, and exit 0. A
second signal or a -9 leaves the buffer in a partial state. If you see a corrupt
`train_history.pkl`, delete it and resume — the checkpoint is still valid.

---

## Current proven parameters (as of 2026-06-30)

```
--channels 128       # bigger net than smoke-test defaults (64); don't reduce
--iters 200          # total iterations; set high and Ctrl-C when done
--eps 100            # self-play episodes per iteration
--sims 100           # MCTS simulations per move
--epochs 4           # training epochs/iteration (was 10 — too big a step, overshot
                     #   away from the good checkpoint; smaller = gentler + faster)
--histwindow 10      # how many past iterations of examples to keep
--arena 40           # head-to-head games for accept/reject (not 20 — too noisy)
--threshold 0.45     # accept if new net wins ≥ 45% (not 0.50 — draws dominate)
--temp-threshold 20  # plies of sampled (temp=1) self-play before greedy (was 15)
--dir-eps 0.25       # Dirichlet ROOT-NOISE weight — self-play exploration (THE fix)
--dir-alpha 0.3      # Dirichlet concentration (~chess-scale branching)
--eval 40            # vs-random eval games
--evalsims 25        # MCTS sims during eval
--export-every 5     # auto-export every 5 accepted checkpoints (for app testing)
--device cpu
--resume
```

These are already in `launch_training.sh`. Override only when debugging.

### Why Dirichlet root noise is the centrepiece (read this)

Stock alpha-zero-general MCTS uses the raw network priors with **no perturbation**.
With `temp=0` after the opening, self-play games become *almost deterministic* —
the net replays the same lines every game and can never discover anything its own
previous version doesn't already do. Symptom we hit: from checkpoint_24 the
candidate net won **0 of 160 arena games** across four iterations — not plateauing,
actively unable to explore.

Real AlphaZero injects exploration by perturbing the **root** priors of each
self-play move:  `P(root) = (1-eps)·p + eps·Dirichlet(alpha)`, eps=0.25. This is
implemented in `capped_mcts.py` (`_add_root_noise`) and is the single most
important lever for escaping the stagnation. Confirmed against the literature
(see "Research notes" below).

**Hard invariant: noise is self-play ONLY.** `execute_episode` passes `play_args`
(which carries `dirichletEps`); `evaluate_head_to_head` and `evaluate_vs_random`
build their own args **without** those keys, so `CappedMCTS.dir_eps` defaults to 0
there. Never add Dirichlet to arena/eval — that would measure a deliberately
perturbed net against the incumbent and make the accept/reject signal meaningless.
If you ever refactor the eval functions, keep their MCTS args noise-free.

---

## If training stagnates (all arena results are REJECT)

Last accepted checkpoint as of 2026-06-30: **checkpoint_24**. Iters 25–28 all
REJECTed with the candidate winning **0 of 160** arena games. **Diagnosed root
cause: no self-play exploration** (no Dirichlet root noise → near-deterministic
self-play). The 2026-06-30 parameter set above adds Dirichlet noise + a gentler
training step to fix exactly this. If checkpoint_24 is still the ceiling after a
full night on the new params, work the list below **in order** — change ONE thing
at a time so you can attribute the result (we learned attribution discipline the
hard way: see Lessons log).

1. **Confirm exploration is actually on.** The startup log line must show
   `dirEps=0.25`. If it shows `dirEps=0.0`, the flags didn't take — fix that first;
   nothing else matters until self-play explores.
2. **Raise `--dir-eps` to 0.35.** More root exploration. Cheap, high-leverage.
3. **Reduce `--sims` to 50.** Halves time per move → ~2× more iterations per night
   → more diverse self-play data overall.
4. **Increase `--eps` to 150.** More self-play games per iteration = stronger,
   less-noisy training signal.
5. **Inspect the loss trend.** If policy + value loss both fall but arena still
   fails, the net learns but can't out-play the incumbent (need more exploration —
   go back to #2). If loss is flat, the step is too small (raise `--epochs` to 6).
6. **NEVER lower `--arena` or `--threshold`** to force an accept. That risks
   keeping a *regressing* net — we proved this: always-accept once collapsed
   vs-random from 75% → 35%. The gate is correct; standard AlphaZero gates at 0.55,
   we're already lenient at 0.45.

---

## Publishing a trained net into the app

The app is the **Electron app** (`drott-electron/`). It runs no Python — it drives
JS MCTS over an **ONNX** model via `onnxruntime-node`. Models live in
`drott-electron/onnx_models/*.onnx`. There is **no `publish.sh`** and no CoreML
anymore; that was the old Swift pipeline.

### Most checkpoints are exported automatically during training

`launch_training.sh` passes `--export-every 5`, so **every accepted iteration whose
number is a multiple of 5 is auto-exported** to
`drott-electron/onnx_models/astrid_it<N>.onnx` (channels matched to the run). If
your good checkpoint landed on one of those, it's already there — skip to "Make
the app see it" below.

### Manual export (any checkpoint, or backfilling)

From `python/`. **You MUST pass `--channels 128`** — the script defaults to 64 and
our nets are 128, so omitting it produces a broken or failed export.

```bash
# one checkpoint → one model file
cd python && python3 export_onnx.py temp/checkpoint_24.pth.tar \
  ../drott-electron/onnx_models/astrid_it24.onnx --channels 128

# or export every temp/checkpoint_N.pth.tar at once → astrid_itN.onnx
cd python && python3 export_onnx.py --all --channels 128
```

Export is **parity-gated**: ONNX must match PyTorch within `1e-3` on both policy and
value, or the file is not written. The contract is `planes(1,18,9,9) → policy(1,6561),
value(1,1)`.

Naming convention the app understands: `astrid_v0`, `astrid_v1`, … (curated
releases) sort before `astrid_it3`, `astrid_it24`, … (per-checkpoint snapshots).

### Make the app see it

`drott-electron/main.js` scans `onnx_models/` at **runtime**, so:

- **Dev run** (fastest for testing a new model): from `drott-electron/`, run
  `npm start` (i.e. `electron .`). It reads the live `onnx_models/` directory —
  just restart the app and the new model appears in **Red/Black Player → Astrid →
  model dropdown**. No rebuild needed.
- **Distributable build**: `npm run dist` bundles `onnx_models/**` into the
  `.dmg`/app. Only needed when you want to ship, not for local testing.

---

## What's automatic vs manual

| Step | Automatic? |
|---|---|
| Saving accepted checkpoints during training | ✅ `python/temp/checkpoint_N.pth.tar` |
| Replay buffer persistence across restarts | ✅ `python/temp/train_history.pkl` (with `--resume`) |
| Exporting a checkpoint to ONNX | ✅ for accepted iters that are multiples of 5 (`--export-every 5`); otherwise ❌ run `export_onnx.py --channels 128` |
| New model appearing in the dropdown | ✅ after the `.onnx` is in `onnx_models/` + app restart (dev) or rebuild (dist) |
| Mac staying awake during training | ✅ caffeinate in `launch_training.sh` |
| Stopping at a set time | ✅ in `launch_training.sh` — edit the `hour=` line to change it |

---

## Storage

- Each checkpoint ≈ 29 MB. `python/temp/` is git-ignored — back it up yourself.
- `train_history.pkl` (the replay buffer) grows to ~1.6 GB for a long run — normal.
- Published ONNX models live in `drott-electron/onnx_models/` (≈ 22–29 MB each) and
  are git-ignored except the `astrid_v0` baseline.

---

## Before touching training code

The Python rules (`python/drott_rules.py`) must always match the Swift engine
(`Sources/Drott/Models.swift`). If Swift rules change, regenerate the parity
corpus and recheck:

```bash
DROTT_DUMP_CORPUS=1 DROTT_CORPUS_OUT=python/parity_corpus.json swift run
cd python && python3 test_parity.py
```

Any mismatch = all training data is invalid. Fix parity before resuming.

---

## Research notes — best practices we verified (2026-06-30)

Grounded in the AlphaZero literature, checked against our actual code:

- **Dirichlet root noise is mandatory for self-play**, not optional. Every correct
  AlphaZero implementation perturbs the root priors so self-play explores. Stock
  alpha-zero-general omits it — that omission was our stagnation. ε=0.25; α scales
  with branching (~0.3 for chess-like games, 0.03 for Go). Source: "Targeted Search
  Control in AlphaZero" (arXiv 2302.12359).
- **Gating (arena accept/reject) is standard and correct.** AlphaGo Zero gated at a
  **55%** win rate; our 0.45 is deliberately *more* lenient. Keep the gate — it is
  what prevents a regressing net from being kept. Source: AlphaZero.jl params.
- **cpuct = 1.0** is the standard default (we match).
- **Temperature schedule**: 1 (sampled) for the opening, then →0 (greedy). We use 20
  plies of temp=1. Standard is "first ~30 moves".
- **Smaller training steps beat bigger ones** near a good checkpoint. Too many
  epochs over the same self-play buffer overfits and overshoots away from the
  incumbent. We cut epochs 10 → 4.

## Lessons log (don't repeat these)

1. **MPS is slower than CPU here.** batch-1 MCTS; MPS per-call overhead dominates.
   One night on MPS = 1 iteration vs several on CPU. Always `--device cpu`.
2. **No-exploration self-play can't escape a local optimum.** checkpoint_24 held for
   many iters with the candidate winning literally 0 arena games until we added
   Dirichlet noise. If the candidate *never* wins, suspect exploration, not the net.
3. **Never force-accept by lowering the gate.** always-accept once collapsed
   vs-random 75% → 35%. A REJECT streak is the gate doing its job; fix exploration
   /step size instead.
4. **Change one lever at a time** when chasing a plateau, so the result is
   attributable and this doc can record *which* fix worked. (The 2026-06-30 run is
   the one allowed exception — three changes at once — because all three are
   well-supported by the literature and one cheap night was worth the bundled bet.)
