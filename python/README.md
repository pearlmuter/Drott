# Drott × AlphaZero — Python side

Training-time code for Drott's learned engine. See `../ALPHAZERO_PLAN.md` for the
full plan. The shipped macOS app runs **no Python** — trained nets are exported to
CoreML and driven by a native Swift MCTS.

## Status

- **Phase 1 — rules port + parity oracle: COMPLETE.**
  `drott_rules.py` is a faithful, dependency-free port of `Sources/Drott/Models.swift`.
  `test_parity.py` proves it reproduces the Swift engine 100% across the golden
  corpus (≈9.5k positions, ≈371k transitions, including king-capture / castle /
  fort win timing). This is the gate against Swift/Python rule drift — no
  neural-net work begins until it is green.

## Files

| File | What it is |
|---|---|
| `drott_rules.py` | The rules: `Board`, legal-move generation for all 9 pieces, `applying`, win conditions, FNV-1a position hash. Stdlib only. |
| `test_parity.py` | Loads the golden corpus and asserts Python == Swift for hashes, legal-move sets, and every transition. |
| `parity_corpus.json` | **Generated** (git-ignored, ~33 MB). The Swift-side oracle. Regenerate any time the Swift rules change (see below). |
| `requirements.txt` | Torch/numpy/coremltools etc. — only needed from Phase 2 on. |
| `drott_game.py` | **Phase 2.** alpha-zero-general `Game` adapter over the rules. |
| `test_game.py` | **Phase 2.** Lockstep proof: the adapter matches drott_rules across 300 games / 31k plies through the full Game API. |
| `drott_nnet.py` | **Phase 2.** PyTorch policy/value net (18 planes → 6561 policy + value) + framework wrapper; MPS or CPU. |
| `capped_mcts.py` | **Phase 2.** Depth-capped MCTS (Drott positions cycle; stock MCTS recurses forever on a repeat). |
| `train_drott.py` | **Phase 2.** Self-contained ply-capped self-play trainer + eval-vs-random smoke run. |

## The parity workflow (run this whenever the Swift rules change)

```bash
# 1. Dump the oracle from the Swift source of truth:
cd ..                       # repo root (Drott/)
DROTT_DUMP_CORPUS=1 DROTT_CORPUS_OUT=python/parity_corpus.json swift run

# 2. Check the Python port still matches it exactly:
cd python
python3 test_parity.py parity_corpus.json
# -> "PARITY OK — Python matches Swift 100%"
```

If parity fails, the Python port has drifted from `Models.swift` — fix
`drott_rules.py` (or the Swift rules, whichever is wrong) before training.

## Phase 2 — running the pipeline

```bash
python3 test_game.py                       # prove the Game adapter matches the rules
python3 train_drott.py --device cpu        # tiny smoke: self-play -> train -> eval vs random
# longer signal:
python3 train_drott.py --iters 3 --eps 10 --sims 25 --maxmoves 160 --eval 20 --device cpu
```

Notes:
- Batch-1 MCTS inference is ~2× faster on **CPU** than MPS here (`--device cpu`);
  MPS wins for big training batches. The trainer defaults to CPU.
- Reaching ≫50% vs random is just compute — pure-Python MCTS on one Mac is slow.

## Next (Phase 3)

CoreML export of a checkpoint (numerical parity vs PyTorch), then a native Swift
MCTS + `NeuralEngine` so the app plays a full game from an exported net.
