#!/usr/bin/env bash
#
# Start a Drott / Astrid training run.
#
#   ./train.sh                 # sensible long-run defaults
#   ./train.sh --iters 20      # override ANY train_drott.py flag (last value wins)
#
# Accepted checkpoints are saved as it goes to  python/temp/checkpoint_N.pth.tar
# (only nets that beat their predecessor in the arena are kept — a clean skill
# ladder). Press Ctrl-C BETWEEN iterations to stop safely; already-saved
# checkpoints are not touched. To make a trained net playable in the app, run
# ./publish.sh afterwards.
#
set -euo pipefail
cd "$(dirname "$0")/python"

echo "Training Astrid → checkpoints land in python/temp/. Ctrl-C between iterations to stop."
echo "Watch the 'vs random' / arena lines to see it improve."
echo

# These defaults are bigger than the smoke run (more episodes/sims, stricter
# arena gate) so the net actually grows. Tune freely; pure-Python MCTS is the
# bottleneck, so expect each iteration to take a while.
exec python3 train_drott.py \
  --iters 60 --eps 30 --sims 50 --maxmoves 200 \
  --arena 20 --threshold 0.6 --histwindow 8 \
  --epochs 10 --channels 64 --eval 30 --evalsims 25 \
  --device cpu "$@"
