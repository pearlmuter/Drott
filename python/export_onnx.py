"""Export a trained Astrid checkpoint to ONNX for the Electron app (Phase 5).

The Electron app runs no Python: it drives JS MCTS over an ONNX model via
onnxruntime-node. This script converts a PyTorch checkpoint and GATES on
numerical parity (ONNX must match PyTorch within 1e-3) before writing the file.

The ONNX model's contract (what onnx-ai.js will rely on):
    input   planes : (1, 18, 9, 9) float32   — 9 piece types x 2 sides, canonical POV
    output  policy : (1, 6561)      float32   — softmax probabilities over from*81+to
    output  value  : (1, 1)         float32   — tanh in [-1, 1], current player's POV

Run:  python3 export_onnx.py [checkpoint.pth.tar] [out.onnx]
      (defaults: temp/checkpoint_4.pth.tar -> ../drott-electron/onnx_models/astrid_v0.onnx)
"""

import os
import sys

import numpy as np
import torch
import torch.nn as nn

from drott_game import DrottGame
from drott_nnet import DrottNNet, grids_to_planes, default_args


class ExportWrapper(nn.Module):
    """DrottNNet wrapped so outputs are (softmax policy, value) not (log_softmax, tanh)."""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, planes):
        log_pi, v = self.net(planes)
        return torch.exp(log_pi), v


def load_net(game, checkpoint, channels):
    from drott_nnet import dotdict
    args = dotdict({"lr": 0.001, "dropout": 0.3, "epochs": 1,
                    "batch_size": 64, "num_channels": channels})
    net = DrottNNet(game, args)
    ck = torch.load(checkpoint, map_location="cpu")
    net.load_state_dict(ck["state_dict"])
    net.eval()
    return net


def main():
    checkpoint = sys.argv[1] if len(sys.argv) > 1 else "temp/checkpoint_4.pth.tar"
    out = sys.argv[2] if len(sys.argv) > 2 else "../../drott-electron/onnx_models/astrid_v0.onnx"
    channels = 64

    game = DrottGame()
    net = load_net(game, checkpoint, channels)
    wrapper = ExportWrapper(net).eval()
    print(f"loaded {checkpoint} (channels={channels})")

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)

    example = torch.zeros(1, 18, 9, 9, dtype=torch.float32)
    tmp = out + ".tmp.onnx"
    torch.onnx.export(
        wrapper,
        example,
        tmp,
        input_names=["planes"],
        output_names=["policy", "value"],
        opset_version=17,
        dynamic_axes={"planes": {0: "batch"}, "policy": {0: "batch"}, "value": {0: "batch"}},
    )
    # Re-save with all weights inline (torch.onnx may split to external .data files).
    import onnx
    model_proto = onnx.load(tmp, load_external_data=True)
    onnx.save_model(model_proto, out, save_as_external_data=False)
    for f in (tmp, tmp + ".data"):
        if os.path.exists(f):
            os.remove(f)
    print(f"exported to {out} ({os.path.getsize(out) // 1024} KB)")

    # --- Parity gate: ONNX must match PyTorch on real boards. ---
    try:
        import onnxruntime as ort
    except ImportError:
        print("onnxruntime not installed — skipping parity check. pip install onnxruntime")
        return

    sess = ort.InferenceSession(out)

    rng = np.random.default_rng(0)
    boards = []
    b = game.getInitBoard()
    cur = 1
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

    print(f"parity: max|Δpolicy|={max_pi:.2e}  max|Δvalue|={max_v:.2e}  (over {len(boards)} boards)")
    if max_pi > 1e-3 or max_v > 1e-3:
        print("PARITY FAILED — removing output file.")
        os.remove(out)
        sys.exit(1)
    print(f"parity OK — {out}")


if __name__ == "__main__":
    main()
