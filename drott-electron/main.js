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
  if (app.dock) app.dock.setIcon(path.join(__dirname, 'assets', 'drott-icon.png'));
  win.loadFile('index.html');
}

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
