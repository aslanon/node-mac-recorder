const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('native system cursor detection preserves resize axes, shapes and stationary changes', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'recorder-cursor-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const version = process.versions.node;
  const candidates = [
    process.env.npm_config_nodedir && path.join(process.env.npm_config_nodedir, 'include/node'),
    path.join(os.homedir(), 'Library/Caches/node-gyp', version, 'include/node'),
    path.join(os.homedir(), '.cache/node-gyp', version, 'include/node'),
    path.resolve(path.dirname(process.execPath), '../include/node'),
  ].filter(Boolean);
  const headers = candidates.find((p) => fs.existsSync(path.join(p, 'node_api.h')));
  assert.ok(headers, 'Node headers required; run npm run rebuild first');
  const binary = path.join(directory, 'cursor-probe.node');
  execFileSync('xcrun', ['clang++', '-std=c++17', '-bundle', '-undefined', 'dynamic_lookup',
    '-DNAPI_DISABLE_CPP_EXCEPTIONS', '-Wno-deprecated-declarations',
    '-I', headers, '-I', path.dirname(require.resolve('node-addon-api')),
    path.join(__dirname, 'cursor-detection-probe.mm'), '-o', binary,
    '-framework', 'AppKit', '-framework', 'ApplicationServices', '-framework', 'Carbon',
  ], { timeout: 60000, stdio: 'pipe' });
  const result = require(binary).run();
  t.diagnostic(`${result.checks} native cursor checks`);
  assert.equal(result.failures, '');
  if (process.env.MAC_RECORDER_TEST_LIVE_CURSOR === '1') {
    const live = require(binary).runLive();
    t.diagnostic(`${live.checks} WindowServer cursor checks`);
    assert.equal(live.failures, '');
  }
});
