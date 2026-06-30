"""Depth-capped MCTS for Drott, with optional Dirichlet root-exploration noise.

The framework's MCTS.search recurses once per ply with no depth bound. That is
fine for Othello (the board fills monotonically, so no line can cycle), but Drott
positions CAN repeat (e.g. kings shuffling). A single MCTS descent that revisits a
position keeps picking the same UCB action and recurses forever -> RecursionError.

This subclass adds a per-descent depth cap: a line longer than `max_depth` is
treated as a neutral (drawish) leaf, value 0. That breaks cycles and bounds the
recursion while leaving the rest of the framework MCTS untouched. Only the
training/eval driver uses it; the proven DrottGame/rules are unchanged.

DIRICHLET ROOT NOISE (the fix for training stagnation, 2026-06-30)
------------------------------------------------------------------
Stock alpha-zero-general MCTS uses the raw network priors with no perturbation, so
with temp=0 after the opening, self-play games are almost deterministic — the net
keeps replaying the same lines and can never discover anything to beat the
incumbent (we saw the candidate win 0 / 160 arena games). Real AlphaZero perturbs
the ROOT priors of each self-play move with Dirichlet noise:
    P(root) = (1 - eps) * p + eps * Dirichlet(alpha)
This is enabled ONLY for self-play (args.dirichletEps > 0). Arena/eval MCTS leave
eps = 0 so they measure the net's TRUE strength against the incumbent — never a
deliberately-perturbed net. Noise is mixed from a cached CLEAN copy of each root's
priors, so a position that recurs as a root gets fresh noise rather than
compounding.
"""

import math

import numpy as np
from MCTS import MCTS, EPS


class CappedMCTS(MCTS):
    def __init__(self, game, nnet, args, max_depth=120):
        super().__init__(game, nnet, args)
        self.max_depth = max_depth
        # Self-play exploration noise (0 = off, the default for arena/eval).
        self.dir_eps = float(args["dirichletEps"]) if "dirichletEps" in args else 0.0
        self.dir_alpha = float(args["dirichletAlpha"]) if "dirichletAlpha" in args else 0.3
        self._root_clean = {}   # s -> unperturbed prior, so re-noising never compounds

    def getActionProb(self, canonicalBoard, temp=1):
        # Perturb the root priors before the simulations (self-play only).
        if self.dir_eps > 0:
            self._add_root_noise(canonicalBoard)
        return super().getActionProb(canonicalBoard, temp)

    def _add_root_noise(self, canonicalBoard):
        s = self.game.stringRepresentation(canonicalBoard)
        if s not in self.Ps:
            self.search(canonicalBoard)   # expand the root so it has priors to perturb
        if s not in self.Ps:
            return                         # terminal root — nothing to perturb
        valids = self.Vs[s]
        idx = np.where(valids)[0]
        if idx.size == 0:
            return
        if s not in self._root_clean:
            self._root_clean[s] = self.Ps[s].copy()
        base = self._root_clean[s]
        noise = np.random.dirichlet([self.dir_alpha] * idx.size)
        ps = base.copy()
        ps[idx] = (1.0 - self.dir_eps) * base[idx] + self.dir_eps * noise
        ps = ps * valids
        tot = ps.sum()
        if tot > 0:
            ps /= tot
        self.Ps[s] = ps

    def search(self, canonicalBoard, depth=0):
        # A line too long to resolve is scored as a draw (0). The minus sign keeps
        # the negamax convention used by the framework.
        if depth >= self.max_depth:
            return 0.0

        s = self.game.stringRepresentation(canonicalBoard)

        if s not in self.Es:
            self.Es[s] = self.game.getGameEnded(canonicalBoard, 1)
        if self.Es[s] != 0:
            return -self.Es[s]

        if s not in self.Ps:
            self.Ps[s], v = self.nnet.predict(canonicalBoard)
            valids = self.game.getValidMoves(canonicalBoard, 1)
            self.Ps[s] = self.Ps[s] * valids
            sum_Ps_s = np.sum(self.Ps[s])
            if sum_Ps_s > 0:
                self.Ps[s] /= sum_Ps_s
            else:
                self.Ps[s] = self.Ps[s] + valids
                self.Ps[s] /= np.sum(self.Ps[s])
            self.Vs[s] = valids
            self.Ns[s] = 0
            return -v

        valids = self.Vs[s]
        cur_best = -float("inf")
        best_act = -1
        for a in range(self.game.getActionSize()):
            if valids[a]:
                if (s, a) in self.Qsa:
                    u = self.Qsa[(s, a)] + self.args.cpuct * self.Ps[s][a] * math.sqrt(self.Ns[s]) / (
                        1 + self.Nsa[(s, a)])
                else:
                    u = self.args.cpuct * self.Ps[s][a] * math.sqrt(self.Ns[s] + EPS)
                if u > cur_best:
                    cur_best = u
                    best_act = a

        a = best_act
        next_s, next_player = self.game.getNextState(canonicalBoard, 1, a)
        next_s = self.game.getCanonicalForm(next_s, next_player)

        v = self.search(next_s, depth + 1)

        if (s, a) in self.Qsa:
            self.Qsa[(s, a)] = (self.Nsa[(s, a)] * self.Qsa[(s, a)] + v) / (self.Nsa[(s, a)] + 1)
            self.Nsa[(s, a)] += 1
        else:
            self.Qsa[(s, a)] = v
            self.Nsa[(s, a)] = 1

        self.Ns[s] += 1
        return -v
