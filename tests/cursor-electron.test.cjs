const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

test('Chromium move and hand cursors survive native capture and press/release', {
  skip: process.platform !== 'darwin', timeout: 20000,
}, (t) => {
  let electron = process.env.MAC_RECORDER_ELECTRON;
  if (!electron) {
    try { electron = require('electron'); } catch {}
  }
  assert.equal(typeof electron, 'string', 'Set MAC_RECORDER_ELECTRON to the Electron executable');
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;
  const run = spawnSync(electron, [path.join(__dirname, 'electron-cursor-fixture.cjs')], {
    env, encoding: 'utf8', timeout: 18000,
  });
  assert.ifError(run.error);
  const output = run.stdout.split('\n').find(line => line.startsWith('CURSOR_RESULTS='));
  assert.ok(output, run.stderr || 'Electron did not return cursor samples');
  const results = JSON.parse(output.slice('CURSOR_RESULTS='.length));
  assert.deepEqual(results.filter(({ expected, actual }) => expected !== actual), []);
  assert.equal(run.status, 0, run.stderr);
  t.diagnostic(`${results.length} real Electron CSS cursor checks`);
});
