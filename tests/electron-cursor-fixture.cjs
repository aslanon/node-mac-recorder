// Run inside Electron. This uses Chromium's actual CSS cursors, which may differ
// from rendering the raw HIServices PDF into an NSImage.
const { app, BrowserWindow, screen } = require('electron');
const addon = require('../build/Release/mac_recorder.node');
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
let window;

app.whenReady().then(async () => {
  const point = screen.getCursorScreenPoint();
  window = new BrowserWindow({
    x: point.x - 100, y: point.y - 60, width: 200, height: 120,
    frame: false, alwaysOnTop: true, skipTaskbar: true,
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  });
  await window.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(
    '<html><body style="margin:0;width:100vw;height:100vh;background:#eee;font:14px sans-serif;display:grid;place-items:center">Cursor detection test</body></html>'
  ));
  window.focus();
  await wait(200);
  const results = [];
  const check = (label, expected) => {
    const actual = addon.getCursorPosition(false)?.cursorType;
    results.push({ label, expected, actual });
  };
  // Repeated transitions catch stale seed/image caches as well as wrong shapes.
  for (const [css, expected] of [
    ['default', 'default'], ['move', 'all-scroll'], ['all-scroll', 'all-scroll'],
    ['grab', 'grab'], ['grabbing', 'grabbing'], ['grab', 'grab'], ['move', 'all-scroll'],
    ['-webkit-grab', 'grab'], ['-webkit-grabbing', 'grabbing'],
    ['help', 'help'], ['progress', 'progress'], ['cell', 'crosshair'],
    ['ns-resize', 'ns-resize'], ['row-resize', 'row-resize'],
    ['nesw-resize', 'nesw-resize'], ['nwse-resize', 'nwse-resize'],
    ['zoom-in', 'zoom-in'], ['zoom-out', 'zoom-out'],
  ]) {
    await window.webContents.executeJavaScript(`document.body.style.cursor=${JSON.stringify(css)}; document.body.textContent=${JSON.stringify(css)}`);
    window.webContents.sendInputEvent({ type: 'mouseMove', x: 100, y: 60 });
    await wait(60);
    check(css, expected);
  }

  // A real renderer switches the displayed hand in response to press/release.
  await window.webContents.executeJavaScript(`
    document.body.style.cursor='grab';
    document.body.onpointerdown=()=>document.body.style.cursor='grabbing';
    document.body.onpointerup=()=>document.body.style.cursor='grab';
    void 0;
  `);
  window.webContents.sendInputEvent({ type: 'mouseMove', x: 100, y: 60 });
  await wait(60);
  check('before press', 'grab');
  window.webContents.sendInputEvent({ type: 'mouseDown', button: 'left', clickCount: 1, x: 100, y: 60 });
  await wait(60);
  check('during press', 'grabbing');
  window.webContents.sendInputEvent({ type: 'mouseUp', button: 'left', clickCount: 1, x: 100, y: 60 });
  await wait(60);
  check('after release', 'grab');
  console.log('CURSOR_RESULTS=' + JSON.stringify(results));
  if (results.some(({ expected, actual }) => expected !== actual)) process.exitCode = 1;
}).catch(error => {
  console.error(error);
  process.exitCode = 1;
}).finally(() => {
  if (window && !window.isDestroyed()) window.destroy();
  app.exit(process.exitCode || 0);
});

setTimeout(() => app.exit(1), 15000).unref();
