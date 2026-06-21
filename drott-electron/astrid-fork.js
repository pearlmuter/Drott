const path = require('path');
globalThis.D = {};
require(path.join(__dirname, 'drott-rules.js'));
require(path.join(__dirname, 'onnx-ai.js'));
const _D = globalThis.D;

process.on('message', async ({ board, modelName, iterations }) => {
  try {
    const move = await _D.astridMove(board, modelName || 'astrid_v1', iterations || 100);
    process.send({ move });
  } catch (e) {
    process.send({ error: String(e) });
  }
});
