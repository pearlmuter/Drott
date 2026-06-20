// drott-rules.test.js — validates JS rules against python/parity_corpus.json
// Run with: bun test
import { describe, test, expect } from 'bun:test';

const { repetitionKey, legalMoves, applyMove } =
  require('./drott-rules.js');

const corpus = require('../Drott/python/parity_corpus.json');

const N = 9;

function buildBoard(pieces, side) {
  const squares = new Array(N * N).fill(null);
  for (const [col, row, type, pSide] of pieces) {
    squares[col + row * N] = { type, side: pSide, col, row };
  }
  return { squares, sideToMove: side, winner: null, winReason: null };
}

const totalMoves = corpus.cases.reduce((s, c) => s + c.moves.length, 0);

describe('drott-rules parity', () => {
  test(`${corpus.cases.length} positions, ${totalMoves} transitions`, () => {
    const errors = [];
    function fail(msg) {
      if (errors.length < 6) errors.push(msg);
    }

    let posKeyFails = 0, countFails = 0, missingFails = 0,
        resultKeyFails = 0, winFails = 0;

    for (const c of corpus.cases) {
      const board = buildBoard(c.pieces, c.side);

      // Position hash
      const posKey = repetitionKey(board).toString();
      if (posKey !== c.key) {
        posKeyFails++;
        fail(`pos hash ${c.id}: expected ${c.key} got ${posKey}`);
      }

      // Legal move set
      const computed = legalMoves(board);
      if (computed.length !== c.moves.length) {
        countFails++;
        fail(`move count ${c.id}: expected ${c.moves.length} got ${computed.length}`);
      }

      // Every corpus transition
      for (const cm of c.moves) {
        const match = computed.find(
          m => m[0][0] === cm.f[0] && m[0][1] === cm.f[1]
            && m[1][0] === cm.t[0] && m[1][1] === cm.t[1]
        );
        if (!match) {
          missingFails++;
          fail(`move missing ${c.id}: [${cm.f}]->[${cm.t}]`);
          continue;
        }

        const res = applyMove(board, match);

        // Post-move position hash
        const resKey = repetitionKey(res).toString();
        if (resKey !== cm.k) {
          resultKeyFails++;
          fail(`result hash ${c.id} [${cm.f}]->[${cm.t}]: expected ${cm.k} got ${resKey}`);
        }

        // Winner / reason
        const w  = res.winner    ?? null;
        const wr = res.winReason ?? null;
        if (w !== (cm.w ?? null) || wr !== (cm.wr ?? null)) {
          winFails++;
          fail(`win ${c.id} [${cm.f}]->[${cm.t}]: expected {${cm.w},${cm.wr}} got {${w},${wr}}`);
        }
      }
    }

    if (errors.length) console.error('\nFirst failures:\n' + errors.join('\n'));

    expect(posKeyFails).toBe(0);
    expect(countFails).toBe(0);
    expect(missingFails).toBe(0);
    expect(resultKeyFails).toBe(0);
    expect(winFails).toBe(0);
  });
});
