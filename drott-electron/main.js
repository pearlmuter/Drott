const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const { fork } = require('child_process');
const path = require('path');
const fs = require('fs');

if (!app.requestSingleInstanceLock()) { app.quit(); }
app.on('second-instance', () => {
  const wins = BrowserWindow.getAllWindows();
  if (wins.length) { wins[0].focus(); }
});

// ---------------------------------------------------------------------------
// Herringbone AI — runs in a separate OS process via child_process.fork
// with ELECTRON_RUN_AS_NODE=1 so the child behaves as plain Node.js.
// The main process never blocks; renderer stays fully responsive.
// ---------------------------------------------------------------------------
let _hrChild   = null;
let _hrResolve = null;

function _killHR() {
  if (_hrChild) { try { _hrChild.kill(); } catch (_) {} _hrChild = null; }
  if (_hrResolve) { _hrResolve(null); _hrResolve = null; }
}

function _hrProcess() {
  if (_hrChild && !_hrChild.killed) return _hrChild;
  _hrChild = fork(
    path.join(__dirname, 'herringbone-fork.js'),
    [],
    { env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' } }
  );
  _hrChild.on('message', (result) => {
    if (_hrResolve) { const r = _hrResolve; _hrResolve = null; r(result); }
  });
  _hrChild.on('error', (err) => {
    console.error('HR fork error:', err);
    if (_hrResolve) { const r = _hrResolve; _hrResolve = null; r({ error: String(err) }); }
    _hrChild = null;
  });
  _hrChild.on('exit', () => {
    _hrChild = null;
    if (_hrResolve) { const r = _hrResolve; _hrResolve = null; r({ error: 'AI process exited' }); }
  });
  return _hrChild;
}

ipcMain.handle('hr-search', (event, { board, thinkTime }) => {
  return new Promise((resolve) => {
    _hrResolve = resolve;
    _hrProcess().send({ board, thinkTime });
  });
});

ipcMain.handle('hr-abort', () => { _killHR(); return null; });

// ---------------------------------------------------------------------------
// Astrid AI — same fork pattern; child runs onnxruntime-node + MCTS in its
// own OS process so the renderer never blocks during neural net inference.
// ---------------------------------------------------------------------------
let _astridChild   = null;
let _astridResolve = null;

function _killAstrid() {
  if (_astridChild) { try { _astridChild.kill(); } catch (_) {} _astridChild = null; }
  if (_astridResolve) { _astridResolve(null); _astridResolve = null; }
}

function _astridProcess() {
  if (_astridChild && !_astridChild.killed) return _astridChild;
  _astridChild = fork(
    path.join(__dirname, 'astrid-fork.js'),
    [],
    { env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' } }
  );
  _astridChild.on('message', (result) => {
    if (_astridResolve) { const r = _astridResolve; _astridResolve = null; r(result); }
  });
  _astridChild.on('error', (err) => {
    console.error('Astrid fork error:', err);
    if (_astridResolve) { const r = _astridResolve; _astridResolve = null; r({ error: String(err) }); }
    _astridChild = null;
  });
  _astridChild.on('exit', () => {
    _astridChild = null;
    if (_astridResolve) { const r = _astridResolve; _astridResolve = null; r({ error: 'Astrid process exited' }); }
  });
  return _astridChild;
}

ipcMain.handle('astrid-search', (event, { board, modelName, iterations }) =>
  new Promise((resolve) => { _astridResolve = resolve; _astridProcess().send({ board, modelName, iterations }); }));

ipcMain.handle('astrid-abort', () => { _killAstrid(); return null; });

// ---------------------------------------------------------------------------

function createWindow() {
  const win = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 960,
    minHeight: 720,
    backgroundColor: '#1a1a1a',
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
    },
  });
  if (app.dock) app.dock.setIcon(path.join(__dirname, 'assets', 'drott-icon-1024.png'));
  win.loadFile('index.html');
}

ipcMain.handle('drott-list-models', () => {
  const dir = path.join(__dirname, 'onnx_models');
  try {
    return fs.readdirSync(dir)
      .filter(f => f.endsWith('.onnx'))
      .map(f => f.slice(0, -5))   // strip .onnx
      .sort((a, b) => {
        // v-series (astrid_v0, astrid_v1) before it-series (astrid_it5, astrid_it10).
        const av = a.match(/^astrid_v(\d+)$/), bv = b.match(/^astrid_v(\d+)$/);
        const ai = a.match(/^astrid_it(\d+)$/), bi = b.match(/^astrid_it(\d+)$/);
        if (av && bv) return parseInt(av[1]) - parseInt(bv[1]);
        if (ai && bi) return parseInt(ai[1]) - parseInt(bi[1]);
        if (av) return -1;   // v before it
        if (bv) return 1;
        return a.localeCompare(b);
      });
  } catch (_) {
    return ['astrid_v2', 'astrid_v1', 'astrid_v0'];
  }
});

ipcMain.handle('drott-save', async (event, content) => {
  const { canceled, filePath } = await dialog.showSaveDialog({
    title: 'Save Game',
    defaultPath: 'drott-game.drott',
    filters: [{ name: 'Drott Game', extensions: ['drott'] }],
  });
  if (canceled || !filePath) return { ok: false };
  fs.writeFileSync(filePath, content, 'utf8');
  return { ok: true };
});

ipcMain.handle('drott-open', async () => {
  const { canceled, filePaths } = await dialog.showOpenDialog({
    title: 'Load Game',
    filters: [{ name: 'Drott Game', extensions: ['drott'] }],
    properties: ['openFile'],
  });
  if (canceled || !filePaths.length) return { ok: false };
  const content = fs.readFileSync(filePaths[0], 'utf8');
  return { ok: true, content };
});

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
