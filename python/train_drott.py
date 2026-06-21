"""Drott AlphaZero training loop.

Supports pause/resume: Ctrl+C finishes the current iteration, saves the
checkpoint, and exits cleanly. Re-run with --resume to continue from where
you left off. --iters always means "N more iterations from now".

Run:
    python3 train_drott.py --channels 128 --iters 20 --eps 100 --sims 100
    python3 train_drott.py --channels 128 --iters 20 --eps 100 --sims 100 --resume
    python3 train_drott.py --channels 128 --iters 20 --eps 100 --sims 100 --resume --export-every 5
"""

import argparse
import glob
import os
import pickle
import re
import signal
import subprocess
import sys
from collections import deque
from random import shuffle

import numpy as np

_AZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "alpha-zero-general-master")
if _AZ not in sys.path:
    sys.path.insert(0, _AZ)
from utils import dotdict

from capped_mcts import CappedMCTS as MCTS
from drott_game import DrottGame
from drott_nnet import NNetWrapper

# ---------------------------------------------------------------------------
# Graceful stop: Ctrl+C finishes the current iteration then saves and exits.
# A second Ctrl+C force-quits immediately.
# ---------------------------------------------------------------------------
_stop_requested = False

def _handle_sigint(sig, frame):
    global _stop_requested
    if _stop_requested:
        print("\nForce quit.")
        sys.exit(1)
    print("\n\nStop requested — finishing current iteration then saving. Ctrl+C again to force quit.")
    _stop_requested = True

signal.signal(signal.SIGINT, _handle_sigint)


# ---------------------------------------------------------------------------
# Resume helpers
# ---------------------------------------------------------------------------

def _find_last_checkpoint(checkpoint_dir):
    """Return (iteration_number, filename) of the highest checkpoint, or (0, None)."""
    pattern = os.path.join(checkpoint_dir, "checkpoint_*.pth.tar")
    files = glob.glob(pattern)
    if not files:
        return 0, None
    best = max(files, key=lambda p: int(re.search(r'checkpoint_(\d+)', p).group(1)))
    n = int(re.search(r'checkpoint_(\d+)', best).group(1))
    return n, os.path.basename(best)


def _history_path(checkpoint_dir):
    return os.path.join(checkpoint_dir, "train_history.pkl")


def _save_history(checkpoint_dir, history):
    with open(_history_path(checkpoint_dir), 'wb') as f:
        pickle.dump(list(history), f)


def _load_history(checkpoint_dir, maxlen):
    p = _history_path(checkpoint_dir)
    if not os.path.exists(p):
        return deque(maxlen=maxlen)
    with open(p, 'rb') as f:
        batches = pickle.load(f)
    d = deque(maxlen=maxlen)
    d.extend(batches)
    return d


# ---------------------------------------------------------------------------

def execute_episode(game, nnet, args):
    """One self-play game -> training examples [(canonicalBoard, pi, value)].
    Mirrors Coach.executeEpisode but with a ply cap that yields a draw (v=0)."""
    mcts = MCTS(game, nnet, args)
    examples = []
    board = game.getInitBoard()
    cur = 1
    step = 0
    while True:
        step += 1
        canon = game.getCanonicalForm(board, cur)
        temp = int(step < args.tempThreshold)
        pi = mcts.getActionProb(canon, temp=temp)
        for b, p in game.getSymmetries(canon, pi):
            examples.append([b, cur, p])
        action = np.random.choice(len(pi), p=pi)
        board, cur = game.getNextState(board, cur, action)
        r = game.getGameEnded(board, cur)
        if r != 0:
            return [(b, p, r * ((-1) ** (player != cur))) for (b, player, p) in examples]
        if step >= args.maxMoves:
            return [(b, p, 0.0) for (b, player, p) in examples]


def random_action(game, canon):
    valids = game.getValidMoves(canon, 1)
    legal = np.where(valids)[0]
    return int(np.random.choice(legal))


def play_match(game, pick_red, pick_black, n_games, cap):
    """Generic head-to-head. Returns (red_fn_wins, black_fn_wins, draws)."""
    a_wins = b_wins = draws = 0
    for i in range(n_games):
        a_is_red = (i % 2 == 0)
        board, cur, step = game.getInitBoard(), 1, 0
        while True:
            canon = game.getCanonicalForm(board, cur)
            a_to_move = (cur == 1) == a_is_red
            action = (pick_red if a_to_move else pick_black)(canon)
            board, cur = game.getNextState(board, cur, action)
            r = game.getGameEnded(board, cur)
            step += 1
            if r != 0:
                winner_player = cur if r > 0 else -cur
                a_player = 1 if a_is_red else -1
                if winner_player == a_player:
                    a_wins += 1
                else:
                    b_wins += 1
                break
            if step >= cap:
                draws += 1
                break
    return a_wins, b_wins, draws


def evaluate_head_to_head(game, new_net, old_net, n_games, sims, cap):
    """Candidate net vs previous net, both with MCTS (temp=0)."""
    args = dotdict({"numMCTSSims": sims, "cpuct": 1.0})
    def mk(net):
        def pick(canon):
            return int(np.argmax(MCTS(game, net, args).getActionProb(canon, temp=0)))
        return pick
    return play_match(game, mk(new_net), mk(old_net), n_games, cap)


def evaluate_vs_random(game, nnet, n_games, sims, cap):
    """Net (MCTS, temp=0) vs uniform-random. Returns (net_wins, random_wins, draws)."""
    eval_args = dotdict({"numMCTSSims": sims, "cpuct": 1.0})
    nw = rw = dr = 0
    for i in range(n_games):
        net_is_red = (i % 2 == 0)
        mcts = MCTS(game, nnet, eval_args)
        board = game.getInitBoard()
        cur = 1
        step = 0
        while True:
            canon = game.getCanonicalForm(board, cur)
            net_to_move = (cur == 1) == net_is_red
            if net_to_move:
                action = int(np.argmax(mcts.getActionProb(canon, temp=0)))
            else:
                action = random_action(game, canon)
            board, cur = game.getNextState(board, cur, action)
            r = game.getGameEnded(board, cur)
            step += 1
            if r != 0:
                winner_player = cur if r > 0 else -cur
                net_player = 1 if net_is_red else -1
                if winner_player == net_player:
                    nw += 1
                else:
                    rw += 1
                break
            if step >= cap:
                dr += 1
                break
    return nw, rw, dr


def main():
    ap = argparse.ArgumentParser(description="Drott AlphaZero trainer")
    ap.add_argument("--iters", type=int, default=2,
                    help="Number of iterations to run (added on top of any prior run)")
    ap.add_argument("--eps", type=int, default=6)
    ap.add_argument("--sims", type=int, default=12)
    ap.add_argument("--maxmoves", type=int, default=80)
    ap.add_argument("--channels", type=int, default=64)
    ap.add_argument("--epochs", type=int, default=4)
    ap.add_argument("--eval", type=int, default=20)
    ap.add_argument("--evalsims", type=int, default=15)
    ap.add_argument("--histwindow", type=int, default=4,
                    help="iterations of self-play examples to retain for training")
    ap.add_argument("--arena", type=int, default=14,
                    help="head-to-head games for the accept/reject gate (0 = always accept)")
    ap.add_argument("--threshold", type=float, default=0.5,
                    help="candidate must win this fraction of DECISIVE arena games to be kept")
    ap.add_argument("--checkpoint", default="temp")
    ap.add_argument("--device", default="cpu",
                    help="cpu (fastest for batch-1 MCTS) | mps | cuda")
    ap.add_argument("--resume", action="store_true",
                    help="Continue from the last checkpoint in --checkpoint dir")
    ap.add_argument("--export-every", type=int, default=0, metavar="N",
                    help="export an ONNX snapshot every N accepted iterations (0=off)")
    ap.add_argument("--out-dir", default=None,
                    help="ONNX output dir for --export-every (default: ../drott-electron/onnx_models)")
    a = ap.parse_args()

    os.makedirs(a.checkpoint, exist_ok=True)

    game = DrottGame()
    net_args = dotdict({"lr": 0.001, "dropout": 0.3, "epochs": a.epochs,
                        "batch_size": 64, "num_channels": a.channels})
    nnet = NNetWrapper(game, net_args, device=a.device)
    pnet = NNetWrapper(game, net_args, device=a.device)

    # --- Resume ---
    start_it = 1
    history = deque(maxlen=a.histwindow)

    if a.resume:
        last_it, last_cp = _find_last_checkpoint(a.checkpoint)
        if last_cp:
            nnet.load_checkpoint(a.checkpoint, last_cp)
            pnet.load_checkpoint(a.checkpoint, last_cp)
            start_it = last_it + 1
            history = _load_history(a.checkpoint, a.histwindow)
            print(f"Resumed from {last_cp}  (iteration {last_it}, "
                  f"history={len(history)} batches)")
        else:
            print("No checkpoint found in '{a.checkpoint}' — starting fresh.")
    else:
        base = evaluate_vs_random(game, nnet, a.eval, a.evalsims, a.maxmoves)
        print(f"baseline (untrained) vs random: net {base[0]} / rand {base[1]} / draw {base[2]}")

    print(f"device: {nnet.device} | running iters {start_it}–{start_it + a.iters - 1} | "
          f"eps={a.eps} sims={a.sims} maxMoves={a.maxmoves} channels={a.channels} "
          f"hist={a.histwindow} arena={a.arena} thr={a.threshold}")

    play_args = dotdict({"numMCTSSims": a.sims, "cpuct": 1.0,
                         "tempThreshold": 15, "maxMoves": a.maxmoves})

    _here = os.path.dirname(os.path.abspath(__file__))
    out_dir = a.out_dir or os.path.join(_here, "..", "drott-electron", "onnx_models")

    for it in range(start_it, start_it + a.iters):
        iter_examples = []
        for e in range(a.eps):
            ex = execute_episode(game, nnet, play_args)
            iter_examples += ex
            print(f"  iter {it} ep {e + 1}/{a.eps}: {len(ex)} examples "
                  f"(total {len(iter_examples)})")
        history.append(iter_examples)
        _save_history(a.checkpoint, history)

        train_examples = [ex for batch in history for ex in batch]
        shuffle(train_examples)

        nnet.save_checkpoint(a.checkpoint, "pre.pth.tar")
        pnet.load_checkpoint(a.checkpoint, "pre.pth.tar")
        print(f"iter {it}: training on {len(train_examples)} examples "
              f"(history of {len(history)} iters)...")
        nnet.train(train_examples)

        accepted = False
        if a.arena > 0:
            nw, ow, dr = evaluate_head_to_head(game, nnet, pnet, a.arena, a.sims, a.maxmoves)
            decisive = nw + ow
            frac = (nw / decisive) if decisive else 0.0
            if decisive == 0 or frac < a.threshold:
                print(f"iter {it} arena: new {nw} / old {ow} / draw {dr} "
                      f"-> REJECT (kept previous net)")
                nnet.load_checkpoint(a.checkpoint, "pre.pth.tar")
            else:
                print(f"iter {it} arena: new {nw} / old {ow} / draw {dr} -> ACCEPT")
                nnet.save_checkpoint(a.checkpoint, f"checkpoint_{it}.pth.tar")
                accepted = True
        else:
            nnet.save_checkpoint(a.checkpoint, f"checkpoint_{it}.pth.tar")
            accepted = True

        if accepted and a.export_every > 0 and it % a.export_every == 0:
            out_path = os.path.join(out_dir, f"astrid_it{it}.onnx")
            cp_path  = os.path.join(a.checkpoint, f"checkpoint_{it}.pth.tar")
            print(f"iter {it}: exporting ONNX snapshot → {out_path}")
            try:
                subprocess.run(
                    [sys.executable, os.path.join(_here, "export_onnx.py"),
                     cp_path, out_path, "--channels", str(a.channels)],
                    check=True,
                )
            except subprocess.CalledProcessError as e:
                print(f"WARNING: ONNX export failed for iter {it}: {e}")

        res = evaluate_vs_random(game, nnet, a.eval, a.evalsims, a.maxmoves)
        total = sum(res)
        wr = 100.0 * res[0] / total if total else 0.0
        print(f"iter {it} vs random: net {res[0]} / rand {res[1]} / draw {res[2]}  "
              f"-> net win rate {wr:.0f}%")

        if _stop_requested:
            print(f"\nStopped after iteration {it}. Resume with --resume.")
            break

    print("\nDone.")


if __name__ == "__main__":
    main()
