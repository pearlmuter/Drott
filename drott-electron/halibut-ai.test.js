// halibut-ai.test.js — sanity checks for the Halibut engine.
import { expect, test } from 'bun:test';

require('./board-state.js');
require('./drott-rules.js');
const HB = require('./halibut-ai.js');
const D = globalThis.D;

const startBoard = D.makeStartBoard();

function isLegal(board, mv) {
  return D.legalMoves(board).some(m =>
    m[0][0] === mv[0][0] && m[0][1] === mv[0][1] &&
    m[1][0] === mv[1][0] && m[1][1] === mv[1][1]);
}

test('search returns a legal best move from the start position', () => {
  const r = HB.search(startBoard, [], 999, 4);
  expect(r.best).not.toBeNull();
  expect(isLegal(startBoard, r.best)).toBe(true);
  expect(r.depth).toBeGreaterThanOrEqual(1);
});

test('depthCap is respected', () => {
  const r = HB.search(startBoard, [], 999, 3);
  expect(r.depth).toBeLessThanOrEqual(3);
});

test('pickMove(variety=0) is deterministic (always the best move)', () => {
  const r = HB.search(startBoard, [], 999, 4);
  for (let i = 0; i < 20; i++) {
    const mv = HB.pickMove(r, startBoard, 0);
    expect(mv[0][0]).toBe(r.best[0][0]);
    expect(mv[0][1]).toBe(r.best[0][1]);
    expect(mv[1][0]).toBe(r.best[1][0]);
    expect(mv[1][1]).toBe(r.best[1][1]);
  }
});

test('pickMove(variety>0) only ever returns legal moves', () => {
  const r = HB.search(startBoard, [], 999, 4);
  for (let i = 0; i < 30; i++) {
    const mv = HB.pickMove(r, startBoard, 80);
    expect(isLegal(startBoard, mv)).toBe(true);
  }
});

test('a self-play sequence only ever plays legal moves', () => {
  let board = startBoard;
  const seen = new Map();
  for (let ply = 0; ply < 40 && !board.winner; ply++) {
    const r = HB.search(board, [], 999, 2);
    if (!r.best) break;                    // no legal moves
    expect(isLegal(board, r.best)).toBe(true);
    board = D.applyMove(board, r.best);
    const k = D.repetitionKey(board).toString();
    const n = (seen.get(k) || 0) + 1;
    seen.set(k, n);
    if (n >= 3) break;                      // threefold — a legal end state
  }
  expect(true).toBe(true);                  // reached here without illegal move / throw
}, 20000);
