"""Export a trained Astrid checkpoint to CoreML for the Swift app (Phase 3.1).

The shipped macOS app runs no Python: it drives a native Swift MCTS over a CoreML
model. This script converts a PyTorch checkpoint to a .mlpackage and GATES on
numerical parity (CoreML must match PyTorch within 1e-3) before writing it, so a
silently-wrong export can't ship.

The CoreML model's contract (what NeuralEngine.swift will rely on):
    input   planes : (1, 18, 9, 9) float32   — 9 piece types x 2 sides, canonical POV
    output  policy : (1, 6561)      float32   — softmax probabilities over from*81+to
    output  value  : (1, 1)         float32   — tanh in [-1, 1], current player's POV

Run:  python3 export_coreml.py [checkpoint.pth.tar] [out.mlpackage]
      (defaults: temp/checkpoint_4.pth.tar -> ../Sources/Drott/Astrid_v0.mlpackage)
"""

import os
import sys

import numpy as np
import torch
import torch.nn as nn
import coremltools as ct

from drott_game import DrottGame
from drott_nnet import DrottNNet, NNetWrapper, grids_to_planes, default_args


class ExportWrapper(nn.Module):
    """Wraps DrottNNet so CoreML sees planes -> (softmax policy, value)."""

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
    folder, filename = os.path.split(checkpoint)
    ck = torch.load(checkpoint, map_location="cpu")
    net.load_state_dict(ck["state_dict"])
    net.eval()
    return net


def main():
    checkpoint = sys.argv[1] if len(sys.argv) > 1 else "temp/checkpoint_4.pth.tar"
    out = sys.argv[2] if len(sys.argv) > 2 else "../Sources/Drott/Astrid_v0.mlpackage"
    channels = 64

    game = DrottGame()
    net = load_net(game, checkpoint, channels)
    wrapper = ExportWrapper(net).eval()
    print(f"loaded {checkpoint} (channels={channels})")

    example = torch.zeros(1, 18, 9, 9, dtype=torch.float32)
    traced = torch.jit.trace(wrapper, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="planes", shape=(1, 18, 9, 9), dtype=np.float32)],
        outputs=[ct.TensorType(name="policy"), ct.TensorType(name="value")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS13,
    )

    # --- Parity gate: CoreML must match PyTorch on real boards. ---
    rng = np.random.default_rng(0)
    boards = []
    b = game.getInitBoard()
    cur = 1
    for _ in range(40):                      # a spread of real positions via random play
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
        planes = grids_to_planes(grid)                          # (1,18,9,9)
        with torch.no_grad():
            t_pi, t_v = wrapper(torch.from_numpy(planes))
        t_pi, t_v = t_pi.numpy()[0], t_v.numpy()[0]
        out_ml = mlmodel.predict({"planes": planes})
        c_pi = np.asarray(out_ml["policy"]).reshape(-1)
        c_v = np.asarray(out_ml["value"]).reshape(-1)
        max_pi = max(max_pi, float(np.max(np.abs(c_pi - t_pi))))
        max_v = max(max_v, float(np.max(np.abs(c_v - t_v))))

    print(f"parity: max|Δpolicy|={max_pi:.2e}  max|Δvalue|={max_v:.2e}  (over {len(boards)} boards)")
    if max_pi > 1e-3 or max_v > 1e-3:
        print("PARITY FAILED — not writing the model.")
        sys.exit(1)

    os.makedirs(os.path.dirname(out), exist_ok=True)
    mlmodel.save(out)
    print(f"parity OK — wrote {out}")


if __name__ == "__main__":
    main()
