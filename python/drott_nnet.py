"""PyTorch policy/value net for Drott + the alpha-zero-general NNet wrapper.

Adapted from othello/pytorch (the canonical reference). Two differences:
  * Input is 18 binary planes (9 piece types x 2 sides) instead of Othello's
    single signed plane. The net only ever sees the CANONICAL board, where the
    side to move is +code, so planes 0..8 are always "my pieces" and 9..17 the
    opponent's — the net learns one POV (ALPHAZERO_PLAN.md §2.1).
  * Runs on Apple-Silicon MPS (falls back to CPU), not CUDA.

The board the wrapper receives is the signed 9x9 grid from drott_game; it expands
it to planes here so the rest of the framework stays grid-based.
"""

import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.optim as optim
from tqdm import tqdm

_AZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "alpha-zero-general-master")
if _AZ not in sys.path:
    sys.path.insert(0, _AZ)
try:
    from NeuralNet import NeuralNet
    from utils import dotdict, AverageMeter
except Exception:  # pragma: no cover
    NeuralNet = object

    class dotdict(dict):
        def __getattr__(self, k):
            return self[k]

from drott_rules import N, TYPE_CODE

NUM_PLANES = 2 * len(TYPE_CODE)   # 18


def pick_device():
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def grids_to_planes(grids):
    """(B,9,9) signed int grid -> (B,18,9,9) float planes.
    plane[code-1] = my pieces of that type (+code); plane[9+code-1] = opponent's."""
    grids = np.asarray(grids)
    if grids.ndim == 2:
        grids = grids[None]
    b = grids.shape[0]
    planes = np.zeros((b, NUM_PLANES, N, N), dtype=np.float32)
    for code in range(1, len(TYPE_CODE) + 1):
        planes[:, code - 1] = (grids == code)
        planes[:, len(TYPE_CODE) + code - 1] = (grids == -code)
    return planes


class DrottNNet(nn.Module):
    def __init__(self, game, args):
        super().__init__()
        self.board_x, self.board_y = game.getBoardSize()
        self.action_size = game.getActionSize()
        self.args = args
        ch = args.num_channels

        self.conv1 = nn.Conv2d(NUM_PLANES, ch, 3, stride=1, padding=1)
        self.conv2 = nn.Conv2d(ch, ch, 3, stride=1, padding=1)
        self.conv3 = nn.Conv2d(ch, ch, 3, stride=1)   # -> (x-2, y-2)
        self.conv4 = nn.Conv2d(ch, ch, 3, stride=1)   # -> (x-4, y-4)
        self.bn1, self.bn2, self.bn3, self.bn4 = (nn.BatchNorm2d(ch) for _ in range(4))

        flat = ch * (self.board_x - 4) * (self.board_y - 4)
        self.fc1 = nn.Linear(flat, 1024)
        self.fc_bn1 = nn.BatchNorm1d(1024)
        self.fc2 = nn.Linear(1024, 512)
        self.fc_bn2 = nn.BatchNorm1d(512)
        self.fc3 = nn.Linear(512, self.action_size)   # policy logits
        self.fc4 = nn.Linear(512, 1)                  # value

    def forward(self, s):
        # s: (batch, 18, 9, 9)
        s = F.relu(self.bn1(self.conv1(s)))
        s = F.relu(self.bn2(self.conv2(s)))
        s = F.relu(self.bn3(self.conv3(s)))
        s = F.relu(self.bn4(self.conv4(s)))
        s = s.view(s.size(0), -1)
        s = F.dropout(F.relu(self.fc_bn1(self.fc1(s))), p=self.args.dropout, training=self.training)
        s = F.dropout(F.relu(self.fc_bn2(self.fc2(s))), p=self.args.dropout, training=self.training)
        pi = self.fc3(s)
        v = self.fc4(s)
        return F.log_softmax(pi, dim=1), torch.tanh(v)


# Sensible smoke-test defaults; the training driver can override num_channels etc.
default_args = dotdict({
    "lr": 0.001,
    "dropout": 0.3,
    "epochs": 10,
    "batch_size": 64,
    "num_channels": 64,
})


class NNetWrapper(NeuralNet):
    def __init__(self, game, args=default_args, device=None):
        self.args = args
        self.device = torch.device(device) if device is not None else pick_device()
        self.nnet = DrottNNet(game, args).to(self.device)
        self.board_x, self.board_y = game.getBoardSize()
        self.action_size = game.getActionSize()

    def train(self, examples):
        """examples: list of (board_grid, pi, v)."""
        optimizer = optim.Adam(self.nnet.parameters(), lr=self.args.lr)
        for epoch in range(self.args.epochs):
            self.nnet.train()
            pi_losses, v_losses = AverageMeter(), AverageMeter()
            batch_count = max(1, int(len(examples) / self.args.batch_size))
            t = tqdm(range(batch_count), desc=f"Train e{epoch + 1}")
            for _ in t:
                ids = np.random.randint(len(examples), size=self.args.batch_size)
                boards, pis, vs = zip(*[examples[i] for i in ids])
                planes = torch.from_numpy(grids_to_planes(np.array(boards))).to(self.device)
                target_pis = torch.FloatTensor(np.array(pis)).to(self.device)
                target_vs = torch.FloatTensor(np.array(vs).astype(np.float64)).to(self.device)

                out_pi, out_v = self.nnet(planes)
                l_pi = self.loss_pi(target_pis, out_pi)
                l_v = self.loss_v(target_vs, out_v)
                total = l_pi + l_v

                pi_losses.update(l_pi.item(), planes.size(0))
                v_losses.update(l_v.item(), planes.size(0))
                t.set_postfix(Loss_pi=pi_losses, Loss_v=v_losses)

                optimizer.zero_grad()
                total.backward()
                optimizer.step()

    def predict(self, board):
        planes = torch.from_numpy(grids_to_planes(board)).to(self.device)
        self.nnet.eval()
        with torch.no_grad():
            pi, v = self.nnet(planes)
        return torch.exp(pi).data.cpu().numpy()[0], v.data.cpu().numpy()[0]

    def loss_pi(self, targets, outputs):
        return -torch.sum(targets * outputs) / targets.size()[0]

    def loss_v(self, targets, outputs):
        return torch.sum((targets - outputs.view(-1)) ** 2) / targets.size()[0]

    def save_checkpoint(self, folder="checkpoint", filename="checkpoint.pth.tar"):
        if not os.path.exists(folder):
            os.makedirs(folder)
        torch.save({"state_dict": self.nnet.state_dict()}, os.path.join(folder, filename))

    def load_checkpoint(self, folder="checkpoint", filename="checkpoint.pth.tar"):
        filepath = os.path.join(folder, filename)
        if not os.path.exists(filepath):
            raise FileNotFoundError(f"No model in path {filepath}")
        checkpoint = torch.load(filepath, map_location=self.device)
        self.nnet.load_state_dict(checkpoint["state_dict"])
