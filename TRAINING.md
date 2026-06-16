# Training Astrid — quick cheat sheet

Two commands. Everything runs from the repo root (`Drott/`).

## 1. Train

```bash
./train.sh
```

- Trains the neural engine; **accepted** checkpoints (ones that beat their
  predecessor in the arena) are saved to `python/temp/checkpoint_N.pth.tar`.
- Watch the `vs random` / `arena` lines — that's the net improving.
- **Stop:** press **Ctrl-C between iterations**. Saved checkpoints are kept; you
  lose only the iteration in progress.
- Override any setting, e.g. a longer run: `./train.sh --iters 200`
- It runs in the foreground. To run overnight in the background and log to a file:
  ```bash
  nohup ./train.sh > train.log 2>&1 &      # stop later with:  pkill -f train_drott
  tail -f train.log                        # watch progress
  ```

> Caveat (today): training is **not** resumable across restarts — a new
> `./train.sh` starts fresh (it keeps the saved checkpoints, but the search tree
> and replay buffer reset). A resumable, signal-clean training *daemon* with
> scheduling is the planned next step (Phase 4) — ask Claude to build it when you
> have budget.

## 2. Publish a trained net into the app

Training does **not** auto-update the app. When a checkpoint looks good:

```bash
./publish.sh                 # newest checkpoint → next free name (Astrid_v1, v2, …)
```

This exports it to CoreML (parity-checked), drops it in `Sources/Drott/models/`,
and rebuilds `Drott.app`. Then:

```bash
pkill -x Drott; open Drott.app
```

The new model **appears automatically** in the app under **Black/Red Player →
Astrid → model dropdown** (the app lists every model in `models/`). Pick a
specific checkpoint or name with `./publish.sh <checkpoint> <Name>`.

## What's automatic vs manual

| Step | Automatic? |
|---|---|
| Saving improved checkpoints during training | ✅ yes (`python/temp/`) |
| Turning a checkpoint into an app-playable model | ❌ run `./publish.sh` |
| New model showing up in the dropdown | ✅ yes, after publish + relaunch |

## Storage

Each checkpoint ≈ 22 MB. Keep the whole accepted ladder if you like (100 ≈ 2.2 GB).
`python/temp/` and published models past `Astrid_v0` are git-ignored — they're
local; back them up yourself if you want to preserve the skill curve.
