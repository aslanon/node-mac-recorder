// All build/clean/install paths share one lock outside node-gyp's build/ tree.
// Concurrent node-gyp processes otherwise delete each other's .deps and
// node_gyp_bins (node-gyp 10's final cleanup does not tolerate a missing dir).
const fs = require('node:fs/promises');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function withNativeBuildLock(directory, operation) {
  directory = await fs.realpath(directory);
  const lock = path.join(directory, '.native-build.lock');
  const inherited = process.env.CREAVIT_NATIVE_BUILD_LOCK;
  const read = () => fs.readFile(path.join(lock, 'owner.json'), 'utf8').then(JSON.parse).catch(() => null);
  if (process.env.CREAVIT_NATIVE_BUILD_ROOT === directory && inherited && (await read())?.token === inherited) return operation();
  const token = randomUUID(), started = Date.now();
  let reported = false;
  while (true) {
    try {
      await fs.mkdir(lock, { mode: 0o700 });
      await fs.writeFile(path.join(lock, 'owner.json'), JSON.stringify({ pid: process.pid, token }), { mode: 0o600 });
      break;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      const owner = await read();
      let stale = false;
      if (owner) {
        try { process.kill(owner.pid, 0); } catch (error) { stale = error.code === 'ESRCH'; }
      } else {
        try { stale = Date.now() - (await fs.stat(lock)).mtimeMs > 30_000; } catch (_) { continue; }
      }
      if (stale) {
        const abandoned = `${lock}.stale-${token}`;
        try { await fs.rename(lock, abandoned); await fs.rm(abandoned, { recursive: true, force: true }); } catch (_) {}
        continue;
      }
      if (!reported) { console.log('[native-build] Waiting for the other native build to finish…'); reported = true; }
      if (Date.now() - started > 600_000) throw new Error('Another native build has held the lock for 10 minutes.');
      await sleep(150);
    }
  }
  const previousRoot = process.env.CREAVIT_NATIVE_BUILD_ROOT, previousToken = process.env.CREAVIT_NATIVE_BUILD_LOCK;
  process.env.CREAVIT_NATIVE_BUILD_ROOT = directory; process.env.CREAVIT_NATIVE_BUILD_LOCK = token;
  try { return await operation(); }
  finally {
    if (previousRoot == null) delete process.env.CREAVIT_NATIVE_BUILD_ROOT; else process.env.CREAVIT_NATIVE_BUILD_ROOT = previousRoot;
    if (previousToken == null) delete process.env.CREAVIT_NATIVE_BUILD_LOCK; else process.env.CREAVIT_NATIVE_BUILD_LOCK = previousToken;
    if ((await read())?.token === token) await fs.rm(lock, { recursive: true, force: true });
  }
}
async function main() {
  const directory = path.resolve(__dirname, '..');
  await withNativeBuildLock(directory, async () => {
    const args = process.argv.slice(2);
    let command = process.execPath, commandArgs;
    if (args[0] === '--exec') { command = args[1]; commandArgs = args.slice(2); }
    else {
      let gyp = process.env.CREAVIT_NODE_GYP_JS;
      if (!gyp) {
        try { gyp = require.resolve('node-gyp/bin/node-gyp.js'); }
        catch { gyp = process.env.npm_config_node_gyp; }
      }
      if (!gyp) throw new Error('node-gyp is unavailable. Run npm install first.');
      if (args[0] === 'build') {
        try { await fs.access(path.join(directory, 'build/config.gypi')); }
        catch { args.unshift('configure'); }
      }
      commandArgs = [gyp, ...args];
    }
    if (!command) throw new Error('Missing native build command');
    const child = spawn(command, commandArgs, { cwd: directory, stdio: 'inherit', env: process.env });
    const forward = signal => child.kill(signal);
    const interrupt = () => forward('SIGINT'), terminate = () => forward('SIGTERM');
    process.on('SIGINT', interrupt); process.on('SIGTERM', terminate);
    try { process.exitCode = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', code => resolve(code ?? 1)); }); }
    finally { process.off('SIGINT', interrupt); process.off('SIGTERM', terminate); }
  });
}
if (require.main === module) main().catch(error => { console.error('[native-build]', error.message); process.exitCode = 1; });
module.exports = { withNativeBuildLock };
