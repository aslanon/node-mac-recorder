const test = require('node:test'), assert = require('node:assert/strict');
const {spawn} = require('node:child_process');
const fs = require('node:fs/promises'), path = require('node:path'), os = require('node:os');
const {withNativeBuildLock} = require('../scripts/native-build.cjs');
const runner = path.resolve(__dirname,'../scripts/native-build.cjs');
function child(directory,id) {
 const code=`const fs=require('node:fs/promises');require(${JSON.stringify(runner)}).withNativeBuildLock(${JSON.stringify(directory)},async()=>{const p=${JSON.stringify(path.join(directory,'events'))};await fs.appendFile(p,'start${id}\\n');await new Promise(r=>setTimeout(r,200));await fs.appendFile(p,'end${id}\\n');}).catch(e=>{console.error(e);process.exitCode=1;});`;
 return new Promise((resolve,reject)=>{let err='';const p=spawn(process.execPath,['-e',code],{stdio:['ignore','ignore','pipe']});p.stderr.on('data',x=>err+=x);p.on('error',reject);p.on('close',c=>c===0?resolve():reject(Error(err)));});
}
test('independent native operations serialize across processes and release the lock',async()=>{
 const directory=await fs.mkdtemp(path.join(os.tmpdir(),'creavit-build-lock-'));
 try{
  await Promise.all([child(directory,1),child(directory,2)]);
  const events=(await fs.readFile(path.join(directory,'events'),'utf8')).trim().split('\n');
  assert.ok(JSON.stringify(events)===JSON.stringify(['start1','end1','start2','end2'])||JSON.stringify(events)===JSON.stringify(['start2','end2','start1','end1']),JSON.stringify(events));
  await assert.rejects(fs.access(path.join(directory,'.native-build.lock')));
 }finally{await fs.rm(directory,{recursive:true,force:true});}
});
test('a failed operation releases the lock and nested build commands reuse the owning lock',async()=>{
 const directory=await fs.mkdtemp(path.join(os.tmpdir(),'creavit-build-fail-'));
 try{
  await assert.rejects(withNativeBuildLock(directory,async()=>{throw Error('compile failed');}),/compile failed/);
  assert.equal(await withNativeBuildLock(directory,()=>withNativeBuildLock(directory,async()=>42)),42);
  await assert.rejects(fs.access(path.join(directory,'.native-build.lock')));
 }finally{await fs.rm(directory,{recursive:true,force:true});}
});
