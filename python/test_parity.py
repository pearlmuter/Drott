"""Parity gate: the Python rules port must reproduce the Swift golden corpus 100%.

Run:  python3 test_parity.py [path/to/parity_corpus.json]

Regenerate the corpus from the Swift side with:
  DROTT_DUMP_CORPUS=1 DROTT_CORPUS_OUT=python/parity_corpus.json swift run

For every case it checks three things, in order of how fundamental they are:
  1. position hash      — reconstructed board's repetition_key matches (encoding)
  2. legal-move set     — the {(from,to,cap)} sets are identical (move generation)
  3. every transition   — each move's (result_key, winner, win_reason) matches
                          (apply + king-capture / castle / fort win timing)

Exits 0 only if all checks pass. Any mismatch is reported with the case id and a
concrete diff, then the run fails — this is the no-go gate before NN training.
"""

import json
import sys

from drott_rules import Board


def load_corpus(path):
    with open(path) as f:
        return json.load(f)


def case_board(case):
    pieces = [(c, r, t, s) for (c, r, t, s) in case["pieces"]]
    return Board.from_pieces(pieces, case["side"])


def run(path):
    corpus = load_corpus(path)
    cases = corpus["cases"]
    print(f"parity check: {len(cases)} cases from {path}")

    n_moves = 0
    hash_fail = 0
    moveset_fail = 0
    trans_fail = 0
    static_fail = 0        # static_outcome(result) must equal applying()'s verdict
    examples = []          # collect a few concrete mismatches to print
    EX_CAP = 12

    def note(kind, case_id, detail):
        if len(examples) < EX_CAP:
            examples.append(f"[{kind}] {case_id}: {detail}")

    for case in cases:
        cid = case["id"]
        b = case_board(case)

        # 1. position hash (board reconstruction / encoding)
        if b.repetition_key() != int(case["key"]):
            hash_fail += 1
            note("hash", cid, f"py={b.repetition_key()} swift={case['key']}")
            continue  # nothing downstream is meaningful if the board differs

        # 2. legal-move set
        py_moves = {}
        for frm, to, cap in b.legal_moves():
            py_moves[(tuple(frm), tuple(to), cap)] = (frm, to, cap)
        sw_moves = {}
        for m in case["moves"]:
            sw_moves[(tuple(m["f"]), tuple(m["t"]), m["cap"])] = m

        if set(py_moves) != set(sw_moves):
            moveset_fail += 1
            only_py = sorted(set(py_moves) - set(sw_moves))
            only_sw = sorted(set(sw_moves) - set(py_moves))
            note("moveset", cid,
                 f"py_only={only_py[:6]} swift_only={only_sw[:6]}")
            # still check the transitions for the moves both agree on
        # 3. transitions for every move present in both
        for key in set(py_moves) & set(sw_moves):
            n_moves += 1
            frm, to, cap = py_moves[key]
            res = b.applying((frm, to, cap))
            m = sw_moves[key]
            exp_w = m["w"]
            exp_wr = m["wr"]
            if (res.repetition_key() != int(m["k"])
                    or res.winner != exp_w
                    or res.win_reason != exp_wr):
                trans_fail += 1
                note("transition", cid,
                     f"move {frm}->{to} cap={cap}: "
                     f"py(k={res.repetition_key()},w={res.winner},wr={res.win_reason}) "
                     f"swift(k={m['k']},w={exp_w},wr={exp_wr})")

            # The static getGameEnded formulation must agree with applying().
            if res.static_outcome() != (res.winner, res.win_reason):
                static_fail += 1
                note("static", cid,
                     f"move {frm}->{to}: static={res.static_outcome()} "
                     f"applying=({res.winner},{res.win_reason})")

    print(f"  checked {n_moves} transitions")
    print(f"  hash mismatches:      {hash_fail}")
    print(f"  move-set mismatches:  {moveset_fail}")
    print(f"  transition mismatches:{trans_fail}")
    print(f"  static-outcome fails: {static_fail}")
    if examples:
        print("\nfirst mismatches:")
        for e in examples:
            print("  " + e)

    ok = (hash_fail == 0 and moveset_fail == 0 and trans_fail == 0 and static_fail == 0)
    print("\n" + ("PARITY OK — Python matches Swift 100%" if ok else "PARITY FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "parity_corpus.json"
    sys.exit(run(path))
