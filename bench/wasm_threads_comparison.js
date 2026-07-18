// Shared WebAssembly Threads source for the zig-js / JavaScriptCore benchmark.
//
// The embedded module is generated from wasm_threads_kernels.wat with WABT
// 1.0.39 (ad75c5edcdff96d73c245b57fbc07607aaca9f95):
//   wat2wasm --enable-threads bench/wasm_threads_kernels.wat -o wasm_threads_kernels.wasm
// SHA-256: 890076044756dcfb67445614cd08d0c73de9529e500d7ec13eeca424ae230d57

var wasmThreadsHex = "0061736d0100000001140460017f006000017f60017f017f60027f7f017f030d0c00000102010303030003030305040103010107a7010d066d656d6f7279020005636c65617200000a636c6561725f6c616e6500010e6c6f61645f636f6e74656e6465640002096c6f61645f6c616e6500030b6c6f61645f6572726f727300040a61746f6d69635f61646400050a61746f6d69635f63617300060f61746f6d69635f6469736a6f696e7400070b636c6561725f706169727300080c7665726966795f7061697273000906776169746572000a086e6f746966696572000b0ac1040c3401017f41004100fe1702000340200141016a4102744100fe170200200141016a210120012000490d000b4180024100fe1702000b1000200041016a4102744100fe1702000b08004100fe1002000b0e00200041016a410274fe1002000b0900418002fe1002000b2501017f02400340200220004f0d0141004101fe1e02001a200241016a21020c000b0b41000b3601027f02400340200220004f0d014100fe100200210341002003200341016afe4802002003470d00200241016a21020c000b0b41000b2f01027f200141016a410274210302400340200220004f0d0120034101fe1e02001a200241016a21020c000b0b41000b3c01027f034041800820014103746a210220024100fe170200200241046a4100fe170200200141016a210120012000490d000b4180024100fe1702000b4301027f02400340200220014f0d0141800820024103746a21032003fe100200200047200341046afe10020020004772044041000f0b200241016a21020c000b0b41010b7701067f41800820014101764103746a2103200341046a210402400340200220004f0d0120034101fe1e020041016a2105024003402004fe1002002106200620054f0d0120042006428094ebdc03fe0102002107200741024604404180024101fe1e02001a0b0c000b0b200241016a21020c000b0b20000b5101037f41800820014101764103746a2103200341046a210402400340200220004f0d012003fe100200200241016a490d0020044101fe1e02001a20044101fe0002001a200241016a21020c000b0b20000b";
var wasmThreadsBytes = new Uint8Array(wasmThreadsHex.length / 2);
for (var wasmThreadsIndex = 0; wasmThreadsIndex < wasmThreadsBytes.length; wasmThreadsIndex = wasmThreadsIndex + 1)
  wasmThreadsBytes[wasmThreadsIndex] = parseInt(wasmThreadsHex.slice(wasmThreadsIndex * 2, wasmThreadsIndex * 2 + 2), 16);

var wasmThreadsModule = new WebAssembly.Module(wasmThreadsBytes);
var wasmThreadsExports = new WebAssembly.Instance(wasmThreadsModule).exports;

function configureThreadsBenchmark(kernel, disjoint) {
  globalThis.__benchmarkPrepare = function (jobs, lanes, lane, shared) {
    if (shared)
      wasmThreadsExports.clear(lanes);
    else if (disjoint)
      wasmThreadsExports.clear_lane(lane);
    else
      wasmThreadsExports.clear(1);
  };
  globalThis.__benchmarkFinish = function (jobs, lanes, lane, shared) {
    if (!disjoint)
      return wasmThreadsExports.load_contended();
    if (!shared)
      return wasmThreadsExports.load_lane(lane);
    var total = 0;
    for (var index = 0; index < lanes; index = index + 1)
      total = total + wasmThreadsExports.load_lane(index);
    return total;
  };
  return function (jobs, lane) { return kernel(jobs, lane); };
}

function configureWaitNotifyBenchmark() {
  globalThis.__benchmarkPrepare = function (jobs, lanes, lane, shared) {
    wasmThreadsExports.clear_pairs(lanes / 2);
  };
  globalThis.__benchmarkFinish = function (jobs, lanes, lane, shared) {
    if (wasmThreadsExports.load_errors() !== 0)
      throw new Error("WebAssembly wait timed out");
    if (wasmThreadsExports.verify_pairs(jobs, lanes / 2) !== 1)
      throw new Error("WebAssembly wait/notify generations did not match");
    return jobs * lanes;
  };
  return function (jobs, lane) {
    return (lane & 1) === 0
      ? wasmThreadsExports.waiter(jobs, lane)
      : wasmThreadsExports.notifier(jobs, lane);
  };
}

function benchmarkFunction(name) {
  if (name === "wasm_threads_atomic_add")
    return configureThreadsBenchmark(wasmThreadsExports.atomic_add, false);
  if (name === "wasm_threads_atomic_cas")
    return configureThreadsBenchmark(wasmThreadsExports.atomic_cas, false);
  if (name === "wasm_threads_atomic_disjoint")
    return configureThreadsBenchmark(wasmThreadsExports.atomic_disjoint, true);
  if (name === "wasm_threads_wait_notify")
    return configureWaitNotifyBenchmark();
  throw new Error("unknown WebAssembly Threads benchmark workload: " + name);
}
