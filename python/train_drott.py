"""Phase 2 sanity training: prove the AlphaZero loop produces a Drott net that
beats a random player.

This is intentionally small and self-contained. It uses the framework's MCTS but
its own self-play / eval loops with a ply cap, so a non-terminating game can never
hang the run (vanilla Coach.executeEpisode and Arena are uncapped). It is NOT the
nightly trainer (that is Phase 4) — it just exercises the whole pipeline end to
end and reports a win rate vs random.

Run:  python3 train_drott.py            # tiny smoke config (~minutes on MPS)
      python3 train_drott.py --iters 4 --eps 16 --sims 25 --eval 40
"""

import argparse
import os
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


def execute_episode(game, nnet, args):
    """One self-play game -> training examples [(canonicalBoard, pi, value)].
    Mirrors Coach.executeEpisode but with a ply cap that yields a draw (v=0)."""
    mcts = MCTS(game, nnet, args)            # fresh tree per game
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
            # r is from `cur`'s POV; assign each example +/-r by whose turn it was.
            return [(b, p, r * ((-1) ** (player != cur))) for (b, player, p) in examples]
        if step >= args.maxMoves:
            return [(b, p, 0.0) for (b, player, p) in examples]


def random_action(game, canon):
    valids = game.getValidMoves(canon, 1)
    legal = np.where(valids)[0]
    return int(np.random.choice(legal))


def play_match(game, pick_red, pick_black, n_games, cap):
    """Generic head-to-head. pick_* (canonicalBoard) -> action. Colours alternate
    so neither side keeps the first-move edge. Returns (red_fn_wins, black_fn_wins,
    draws) tallied per *function*, not per colour."""
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
    """Candidate net vs previous net, both with MCTS (temp=0). Fresh tree per game."""
    args = dotdict({"numMCTSSims": sims, "cpuct": 1.0})

    def mk(net):
        def pick(canon):
            return int(np.argmax(MCTS(game, net, args).getActionProb(canon, temp=0)))
        return pick

    return play_match(game, mk(new_net), mk(old_net), n_games, cap)


def evaluate_vs_random(game, nnet, n_games, sims, cap):
    """Net (MCTS, temp=0) vs uniform-random. Alternates colours. Returns
    (net_wins, random_wins, draws)."""
    eval_args = dotdict({"numMCTSSims": sims, "cpuct": 1.0})
    nw = rw = dr = 0
    for i in range(n_games):
        net_is_red = (i % 2 == 0)
        mcts = MCTS(game, nnet, eval_args)   # fresh tree per game
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
                winner_player = cur if r > 0 else -cur     # 1=red, -1=black
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
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=2)
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
    a = ap.parse_args()

    game = DrottGame()
    net_args = dotdict({"lr": 0.001, "dropout": 0.3, "epochs": a.epochs,
                        "batch_size": 64, "num_channels": a.channels})
    nnet = NNetWrapper(game, net_args, device=a.device)
    pnet = NNetWrapper(game, net_args, device=a.device)   # previous-net for the gate
    print(f"device: {nnet.device} | iters={a.iters} eps={a.eps} sims={a.sims} "
          f"maxMoves={a.maxmoves} channels={a.channels} hist={a.histwindow} "
          f"arena={a.arena} thr={a.threshold}")

    play_args = dotdict({"numMCTSSims": a.sims, "cpuct": 1.0,
                         "tempThreshold": 15, "maxMoves": a.maxmoves})

    base = evaluate_vs_random(game, nnet, a.eval, a.evalsims, a.maxmoves)
    print(f"baseline (untrained) vs random: net {base[0]} / rand {base[1]} / draw {base[2]}")

    history = deque(maxlen=a.histwindow)   # each entry: one iteration's examples
    for it in range(1, a.iters + 1):
        iter_examples = []
        for e in range(a.eps):
            ex = execute_episode(game, nnet, play_args)
            iter_examples += ex
            print(f"  iter {it} ep {e + 1}/{a.eps}: {len(ex)} examples (total {len(iter_examples)})")
        history.append(iter_examples)
        train_examples = [ex for batch in history for ex in batch]
        shuffle(train_examples)

        # Keep a copy of the current net as the challenger baseline, then train.
        nnet.save_checkpoint(a.checkpoint, "pre.pth.tar")
        pnet.load_checkpoint(a.checkpoint, "pre.pth.tar")
        print(f"iter {it}: training on {len(train_examples)} examples "
              f"(history of {len(history)} iters)...")
        nnet.train(train_examples)

        # Accept/reject gate: keep the new net only if it actually beats the old.
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
        else:
            nnet.save_checkpoint(a.checkpoint, f"checkpoint_{it}.pth.tar")

        res = evaluate_vs_random(game, nnet, a.eval, a.evalsims, a.maxmoves)
        total = sum(res)
        wr = 100.0 * res[0] / total if total else 0.0
        print(f"iter {it} vs random: net {res[0]} / rand {res[1]} / draw {res[2]}  "
              f"-> net win rate {wr:.0f}%")

    print("\nPhase 2 smoke run complete.")


if __name__ == "__main__":
    main()
