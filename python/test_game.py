"""Prove the DrottGame adapter stays in lockstep with the parity-proven rules.

Run:  python3 test_game.py

It drives random self-play through the *exact* call sequence Coach/Arena use
(getCanonicalForm -> getValidMoves(canon,1) -> sample canonical action ->
getNextState(realBoard, realPlayer, action) -> getGameEnded), while running a
parallel ground-truth game directly on drott_rules.Board in the absolute frame.
At every ply it asserts:

  * start encoding matches the Swift engine's start hash (cross-checks getInitBoard),
  * the framework's canonical legal-move set, mapped back to the absolute frame,
    equals drott_rules' legal moves (proves canonical form + action remap),
  * the framework grid equals board_to_grid(truth) after every move
    (proves getNextState + encode/decode round-trip),
  * getGameEnded agrees with drott_rules' terminal verdict.

drott_rules is already proven == Swift (test_parity.py), so a green run here makes
DrottGame correct transitively. No torch / framework training needed.
"""

import random

import numpy as np

import drott_rules
from drott_game import (
    DrottGame, START_PIECES, grid_to_board, board_to_grid,
    rot180_action, decode_action, encode_action,
)

SWIFT_START_KEY = 9054274051346406550  # corpus case "start.red"


def to_abs_action(action, player):
    """A canonical-frame action -> the absolute-frame action for `player`."""
    return action if player == 1 else rot180_action(action)


def truth_legal_abs(truth):
    return {encode_action(frm, to) for frm, to, _ in truth.legal_moves()}


def run(num_games=300, ply_cap=250, seed0=0):
    g = DrottGame()

    # 0. Start encoding must match the Swift engine exactly.
    start = g.getInitBoard()
    start_key = grid_to_board(start, "red").repetition_key()
    assert start_key == SWIFT_START_KEY, f"start key {start_key} != Swift {SWIFT_START_KEY}"

    plies = 0
    terminals = {"red": 0, "black": 0, "nomove": 0, "cap": 0}

    for gi in range(num_games):
        rng = random.Random(seed0 + gi)
        board = g.getInitBoard()
        cur = 1
        truth = grid_to_board(board, "red")

        for _ in range(ply_cap):
            plies += 1

            # grid <-> truth must agree, and player sign must match side to move.
            assert np.array_equal(board, board_to_grid(truth)), f"grid drift @game{gi}"
            assert (cur == 1) == (truth.side_to_move == "red"), f"player drift @game{gi}"

            # legal-move parity through the canonical API.
            canon = g.getCanonicalForm(board, cur)
            valids = g.getValidMoves(canon, 1)
            fw_canon = {a for a in range(g.getActionSize()) if valids[a]}
            fw_abs = {to_abs_action(a, cur) for a in fw_canon}
            assert fw_abs == truth_legal_abs(truth), (
                f"legal-move mismatch @game{gi} cur={cur}: "
                f"fw_only={sorted(fw_abs - truth_legal_abs(truth))[:4]} "
                f"truth_only={sorted(truth_legal_abs(truth) - fw_abs)[:4]}")

            # terminal agreement (game still going here).
            ended = g.getGameEnded(board, cur)
            t_winner, _ = truth.static_outcome()
            if t_winner is not None:
                # shouldn't happen mid-loop: we break right after a terminal move.
                raise AssertionError(f"unexpected standing winner @game{gi}")
            if not fw_canon:                      # stalemate: side to move loses
                assert ended == -1.0, f"no-move not flagged terminal @game{gi}"
                terminals["nomove"] += 1
                break
            assert ended == 0.0, f"getGameEnded should be 0 @game{gi}, got {ended}"

            # take a random canonical action; apply through the API and on truth.
            a_canon = rng.choice(tuple(fw_canon))
            a_abs = to_abs_action(a_canon, cur)
            frm, to = decode_action(a_abs)
            is_cap = truth.piece_at(*to) is not None

            board, cur = g.getNextState(board, cur, a_canon)
            truth = truth.applying((frm, to, is_cap))

            assert np.array_equal(board, board_to_grid(truth)), f"post-move grid drift @game{gi}"
            assert (cur == 1) == (truth.side_to_move == "red"), f"post-move player drift @game{gi}"

            if truth.winner is not None:
                # The framework must now see a decisive result for the side to move.
                end2 = g.getGameEnded(board, cur)
                assert end2 != 0.0, f"terminal not detected @game{gi}"
                # getGameEnded is from `cur`'s POV; the side to move was just
                # mated / outplayed, so it should read as a loss (or the static
                # castle/fort/king verdict for whoever the winner is).
                expected = 1.0 if truth.winner == ("red" if cur == 1 else "black") else -1.0
                assert end2 == expected, f"terminal sign wrong @game{gi}: {end2} != {expected}"
                terminals[truth.winner if truth.winner in terminals else "cap"] += 1
                terminals["cap"] += 1
                break

    print(f"lockstep OK: {num_games} games, {plies} plies checked")
    print(f"  start hash matches Swift: {start_key}")
    print(f"  terminals: {terminals}")
    print("\nDrottGame matches drott_rules (== Swift) through the full Game API.")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
