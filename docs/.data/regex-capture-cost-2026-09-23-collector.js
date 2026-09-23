const fs = require('fs');
const cp = require('child_process');
const crypto = require('crypto');
const root = '/private/tmp/zig-js-sep23-verification.xkalXk';
const repo = '/Users/glennmichaeltorregosa/Documents/Projects/zig-js';
const deps = {before: root + '/zig-regex', after: '/Users/glennmichaeltorregosa/Documents/Projects/zig-regex'};
const rows = [['max_bound',16546],['failed_extra',16032],['exact_bound_control',16546],['lazy_control',354]];
const out = root + '/capture-cost.json';
function command(file,args) { return cp.execFileSync(file,args,{encoding:'utf8'}).trim(); }
function git(dir,...args) { return command('git',['-C',dir,...args]); }
function hash(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
for (const dir of [repo,...Object.values(deps)]) if (git(dir,'status','--porcelain','--untracked-files=no')) throw Error('Dirty measured source: '+dir);
git(repo,'ls-files','--error-unmatch','bench/regex_capture_rollback.zig');
const revisions = Object.fromEntries(Object.entries(deps).map(([k,v])=>[k,git(v,'rev-parse','HEAD')]));
if(git(deps.after,'rev-parse','HEAD^') !== revisions.before) throw Error('Not exact parent');
if(fs.existsSync(out)) throw Error('Refusing to replace prior measurement');
const artifact = {
  schema:1, kind:'regex_library_capture_rollback_cost', status:'incomplete', hostClass:'diagnostic',
  startedAt:new Date().toISOString(), sourceRevision:git(repo,'rev-parse','HEAD'),
  sourcePath:'bench/regex_capture_rollback.zig', sourceSha256:hash(repo+'/bench/regex_capture_rollback.zig'),
  collectorSha256:hash(__filename), revisions,
  binaries:Object.fromEntries(['before','after'].map(k=>[k,{path:root+'/capture-bench-'+k,sha256:hash(root+'/capture-bench-'+k)}])),
  host:{cpu:command('/usr/sbin/sysctl',['-n','machdep.cpu.brand_string']),memoryBytes:+command('/usr/sbin/sysctl',['-n','hw.memsize']),cpus:+command('/usr/sbin/sysctl',['-n','hw.ncpu']),os:command('/usr/bin/sw_vers',[]),power:command('/usr/bin/pmset',['-g','batt'])},
  toolchain:{zig:command('/Users/glennmichaeltorregosa/zig-aarch64-macos-0.17.0-dev.1441+d5181a9c9/zig',['version']),mode:'ReleaseFast',allocator:'std.heap.c_allocator',node:process.version},
  protocol:{samplesPerSide:7,warmups:10,targetCalibrationNs:200000000,minimumSampleNs:50000000,order:'alternate parent/candidate within each pair',discardedSamples:0,timedBoundary:'reused matcher findFrom(0), exact result validation, checksum, and result destruction; excludes regex compilation, process startup, and ten warmups',scope:'four bounded-repeat library controls with identical Node-confirmed results; not an engine or JSC comparison',thermal:'unavailable',instructions:'unavailable',energy:'unavailable'},
  calibration:[], plan:[], samples:[]
};
function save() { fs.writeFileSync(out,JSON.stringify(artifact,null,2)+'\n'); }
function run(side,row,iterations,expected) {
  const result=cp.spawnSync(root+'/capture-bench-'+side,[row,String(iterations)],{encoding:'utf8',maxBuffer:1024*1024});
  const m=result.stderr && result.stderr.match(/^SAMPLE\t(\S+)\t(\d+)\t(\d+)\t(\d+)$/m);
  const record={side,row,iterations,status:result.status,signal:result.signal,stdout:result.stdout,stderr:result.stderr};
  if(result.status!==0||!m||m[1]!==row||+m[2]!==iterations||+m[4]!==iterations*expected) {
    artifact.failure=record;save();throw Error('Invalid benchmark result');
  }
  return {...record,elapsedNs:+m[3],checksum:+m[4]};
}
save();
for(const [row,expected] of rows) {
  const pair=['before','after'].map(side=>run(side,row,100,expected));
  artifact.calibration.push(...pair);
  const fastest=Math.min(...pair.map(x=>x.elapsedNs));
  if(fastest<=0)throw Error('Invalid clock observation');
  const iterations=Math.max(100,Math.ceil(200000000/fastest*100));
  if(iterations>1000000)throw Error('Calibration exceeds fixed runner limit');
  artifact.plan.push({row,iterations,checksum:iterations*expected});save();
  console.log(`CALIBRATED ${row} iterations=${iterations}`);
}
for(let sample=0;sample<7;sample++) {
  for(let index=0;index<rows.length;index++) {
    const [row,expected]=rows[index], plan=artifact.plan[index];
    const order=(sample+index)%2===0?['before','after']:['after','before'];
    for(const side of order) {
      artifact.samples.push({sample,...run(side,row,plan.iterations,expected)});save();
    }
  }
  console.log(`PAIR_ROUND_COMPLETE ${sample+1}/7`);
}
artifact.endedAt=new Date().toISOString();
artifact.powerAfter=command('/usr/bin/pmset',['-g','batt']);
artifact.belowTimingFloor=artifact.samples.filter(s=>s.elapsedNs<50000000).map(s=>({sample:s.sample,row:s.row,side:s.side}));
artifact.status='complete';save();
console.log(`CAPTURE_COST_COMPLETE samples=${artifact.samples.length} belowFloor=${artifact.belowTimingFloor.length}`);
