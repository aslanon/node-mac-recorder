const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('iPhone, camera and microphone preserve one media timeline through delayed startup and pauses', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'recorder-ios-sync-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const headers = [
    process.env.npm_config_nodedir && path.join(process.env.npm_config_nodedir, 'include/node'),
    path.join(os.homedir(), 'Library/Caches/node-gyp', process.versions.node, 'include/node'),
    path.resolve(path.dirname(process.execPath), '../include/node'),
  ].filter(Boolean).find((p) => fs.existsSync(path.join(p, 'node_api.h')));
  assert.ok(headers, 'Node headers required; run npm run rebuild first');
  const binary = path.join(directory, 'ios-sync-probe.node');
  execFileSync('xcrun', ['clang++', '-std=c++17', '-bundle', '-undefined', 'dynamic_lookup',
    '-DNAPI_DISABLE_CPP_EXCEPTIONS', '-Wno-deprecated-declarations',
    '-I', headers, '-I', path.dirname(require.resolve('node-addon-api')),
    path.join(__dirname, 'ios-sync-probe.mm'), '-o', binary,
    ...['Foundation', 'AVFoundation', 'CoreMedia', 'CoreVideo', 'CoreMediaIO', 'IOKit', 'CoreAudio']
      .flatMap((framework) => ['-framework', framework]),
  ], { timeout: 60000, stdio: 'pipe' });
  const result = require(binary).run(directory);
  t.diagnostic(`${result.checks} native timing and MOV checks`);
  assert.equal(result.failures, '');
});
