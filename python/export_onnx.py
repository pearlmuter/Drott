"""Export a trained Astrid checkpoint to ONNX for the Electron app.

The Electron app runs no Python: it drives JS MCTS over an ONNX model via
onnxruntime-node. This script converts a PyTorch checkpoint and GATES on
numerical parity (ONNX must match PyTorch within 1e-3) before writing the file.

The ONNX model's contract (what onnx-ai.js will rely on):
    input   planes : (1, 18, 9, 9) float32   — 9 piece types x 2 sides, canonical POV
    output  policy : (1, 6561)      float32   — softmax probabilities over from*81+to
    output  value  : (1, 1)         float32   — tanh in [-1, 1], current player's POV

Run:
    python3 export_onnx.py checkpoint.pth.tar out.onnx [--channels 64]
    python3 export_onnx.py --all [--out-dir ../drott-electron/onnx_models] [--channels 64]

Defaults (single-file mode):
    checkpoint : temp/checkpoint_4.pth.tar
    out        : ../drott-electron/onnx_models/astrid_v0.onnx

--all scans temp/checkpoint_N.pth.tar and exports each as astrid_itN.onnx.
"""

import argparse
import glob
import os
import re
import sys

import numpy as np
import torch
import torch.nn as nn

from drott_game import DrottGame
from drott_nnet import DrottNNet, grids_to_planes

_HERE = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_OUT_DIR = os.path.join(_HERE, "..", "drott-electron", "onnx_models")


class ExportWrapper(nn.Module):
    """DrottNNet wrapped so outputs are (softmax policy, value) not (log_softmax, tanh)."""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, planes):
        log_pi, v = self.net(planes)
        return torch.exp(log_pi), v


def _load_net(game, checkpoint, channels):
    from drott_nnet import dotdict
    args = dotdict({"lr": 0.001, "dropout": 0.3, "epochs": 1,
                    "batch_size": 64, "num_channels": channels})
    net = DrottNNet(game, args)
    ck = torch.load(checkpoint, map_location="cpu", weights_only=False)
    net.load_state_dict(ck["state_dict"])
    net.eval()
    return net


def export_one(checkpoint, out, channels, game=None, *, parity=True):
    """Export one checkpoint to ONNX. Returns True on success."""
    if game is None:
        game = DrottGame()
    net = _load_net(game, checkpoint, channels)
    wrapper = ExportWrapper(net).eval()
    print(f"loaded  {checkpoint}  (channels={channels})")

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)

    example = torch.zeros(1, 18, 9, 9, dtype=torch.float32)
    tmp = out + ".tmp.onnx"
    torch.onnx.export(
        wrapper, example, tmp,
        input_names=["planes"], output_names=["policy", "value"],
        opset_version=17,
        dynamic_axes={"planes": {0: "batch"}, "policy": {0: "batch"}, "value": {0: "batch"}},
    )
    # Re-save with all weights inline (torch.onnx may split to external .data files).
    import onnx
    model_proto = onnx.load(tmp, load_external_data=True)
    onnx.save_model(model_proto, out, save_as_external_data=False)
    for f in (tmp, tmp + ".data"):
        if os.path.exists(f): os.remove(f)
    print(f"written {out}  ({os.path.getsize(out) // 1024} KB)")

    if not parity:
        return True

    try:
        import onnxruntime as ort
    except ImportError:
        print("onnxruntime not installed — skipping parity check.")
        return True

    sess = ort.InferenceSession(out)
    rng = np.random.default_rng(0)
    boards = []
    b, cur = game.getInitBoard(), 1
    for _ in range(40):
        boards.append(game.getCanonicalForm(b, cur))
        valids = game.getValidMoves(game.getCanonicalForm(b, cur), 1)
        legal = np.where(valids)[0]
        if len(legal) == 0:
            b, cur = game.getInitBoard(), 1
            continue
        b, cur = game.getNextState(b, cur, int(rng.choice(legal)))
        if game.getGameEnded(b, cur) != 0:
            b, cur = game.getInitBoard(), 1

    max_pi = max_v = 0.0
    for grid in boards:
        planes = grids_to_planes(grid)
        with torch.no_grad():
            t_pi, t_v = wrapper(torch.from_numpy(planes))
        t_pi, t_v = t_pi.numpy()[0], t_v.numpy()[0]
        o_pi, o_v = sess.run(None, {"planes": planes})
        max_pi = max(max_pi, float(np.max(np.abs(o_pi[0] - t_pi))))
        max_v  = max(max_v,  float(np.max(np.abs(o_v[0]  - t_v))))

    print(f"parity  max|Δpolicy|={max_pi:.2e}  max|Δvalue|={max_v:.2e}  ({len(boards)} boards)")
    if max_pi > 1e-3 or max_v > 1e-3:
        print("PARITY FAILED — removing output file.")
        os.remove(out)
        return False
    print("parity OK")
    return True


def main():
    ap = argparse.ArgumentParser(description="Export Astrid checkpoint(s) to ONNX")
    ap.add_argument("checkpoint", nargs="?", default="temp/checkpoint_4.pth.tar",
                    help="PyTorch checkpoint (single-file mode)")
    ap.add_argument("out", nargs="?",
                    default=os.path.join(_DEFAULT_OUT_DIR, "astrid_v0.onnx"),
                    help="Output .onnx path (single-file mode)")
    ap.add_argument("--channels", type=int, default=64,
                    help="Model channel width — must match the training run (default 64)")
    ap.add_argument("--all", dest="all_", action="store_true",
                    help="Export every temp/checkpoint_N.pth.tar as astrid_itN.onnx")
    ap.add_argument("--out-dir", default=_DEFAULT_OUT_DIR,
                    help="Output directory for --all mode")
    a = ap.parse_args()

    game = DrottGame()

    if a.all_:
        pattern = os.path.join(os.path.dirname(a.checkpoint) or "temp", "checkpoint_*.pth.tar")
        cps = sorted(glob.glob(pattern),
                     key=lambda p: int(re.search(r'checkpoint_(\d+)', p).group(1)))
        if not cps:
            print(f"No checkpoints found matching {pattern}")
            sys.exit(1)
        ok = 0
        for cp in cps:
            n = re.search(r'checkpoint_(\d+)', cp).group(1)
            out = os.path.join(a.out_dir, f"astrid_it{n}.onnx")
            if export_one(cp, out, a.channels, game):
                ok += 1
        print(f"\n{ok}/{len(cps)} exported successfully.")
        if ok < len(cps): sys.exit(1)
    else:
        if not export_one(a.checkpoint, a.out, a.channels, game):
            sys.exit(1)


if __name__ == "__main__":
    main()
