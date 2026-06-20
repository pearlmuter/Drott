// onnx-ai.test.js — sanity checks for encoding helpers (no ONNX model needed)
import { expect, test } from 'bun:test';

// Load just the encoding helpers via module.exports
const { fillPlanes, realAction, canonicalAction } = require('./onnx-ai.js');

// board-state and drott-rules must be loaded for fillPlanes to access D.*
require('./board-state.js');
require('./drott-rules.js');

const startBoard = globalThis.D.makeStartBoard();

test('realAction round-trips col/row pairs', () => {
  expect(realAction([0, 0], [0, 0])).toBe(0);
  expect(realAction([8, 8], [8, 8])).toBe(ACTION_SIZE - 1);
  expect(realAction([4, 4], [5, 4])).toBe((4 + 4 * 9) * 81 + (5 + 4 * 9));
});

const ACTION_SIZE = 6561;

test('canonicalAction: Red is identity', () => {
  for (const idx of [0, 1, 40, 80, 6560]) {
    expect(canonicalAction(idx, 'red')).toBe(idx);
  }
});

test('canonicalAction: Black rotates 180°', () => {
  // sq 0 → 80, sq 80 → 0
  expect(canonicalAction(0 * 81 + 0, 'black')).toBe(80 * 81 + 80);
  expect(canonicalAction(80 * 81 + 80, 'black')).toBe(0 * 81 + 0);
  // self-inverse
  for (const idx of [0, 1000, 3280, 6560]) {
    expect(canonicalAction(canonicalAction(idx, 'black'), 'black')).toBe(idx);
  }
});

test('fillPlanes: start board has correct piece counts', () => {
  const buf = fillPlanes(startBoard, 'red');
  // Each plane sums to the number of pieces of that type for that side
  const planeSum = (pl) => {
    let s = 0;
    for (let i = 0; i < 81; i++) s += buf[pl * 81 + i];
    return s;
  };
  // Red pieces: planes 0-8; Black pieces: planes 9-17
  // Total red pieces = total black pieces (symmetric start)
  let redTotal = 0, blackTotal = 0;
  for (let pl = 0; pl < 9;  pl++) redTotal   += planeSum(pl);
  for (let pl = 9; pl < 18; pl++) blackTotal += planeSum(pl);
  expect(redTotal).toBe(blackTotal);
  // king plane (code 1, index 0) has exactly 1 red king
  expect(planeSum(0)).toBe(1);
});

test('fillPlanes: Black POV rotates 180°', () => {
  const redBuf   = fillPlanes(startBoard, 'red');
  const blackBuf = fillPlanes(startBoard, 'black');
  // From Black's POV, Black's own pieces appear in planes 0-8
  // The Black king is at (4, 8) → rotated to (4, 0) in canonical frame
  // Plane 0 (king, index 0) should have a 1 at row=0, col=4
  expect(blackBuf[(0 * 9 + 0) * 9 + 4]).toBe(1);  // king at canonical (col=4, row=0)
  // From Red's POV, Red king is at (4, 0) which stays (4, 0) in canonical frame
  expect(redBuf[(0 * 9 + 0) * 9 + 4]).toBe(1);
});
