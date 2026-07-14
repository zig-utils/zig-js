// Shared source for the zig-js / JavaScriptCore comparison benchmark.
//
// Keep this file host-API-free: both runners evaluate these exact bytes. Each
// workload returns a deterministic, exactly representable integer checksum.
// The `jobs` argument is the unit reported by the benchmark driver; parallel
// rows run `jobs` independently in every lane.

function benchmarkArithmetic(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var value = lane + job + 1;
    for (var i = 0; i < 100000; i = i + 1)
      value = (value + i + lane) % 1000003;
    total = total + value;
  }
  return total;
}

function benchmarkProperties(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var object = { a: lane + job, b: 1, c: 2, d: 3 };
    for (var i = 0; i < 25000; i = i + 1) {
      object.a = (object.a + i) % 1000003;
      object.b = object.b + 1;
      object.c = object.a + object.b;
      object.d = object.c - object.b;
    }
    total = total + object.a + object.b + object.c + object.d;
  }
  return total;
}

function benchmarkArrays(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var values = [];
    for (var i = 0; i < 10000; i = i + 1)
      values.push((i + job + lane) & 65535);
    for (var j = 0; j < values.length; j = j + 1)
      total = total + values[j];
  }
  return total;
}

function benchmarkDirectCallStep(value, delta) {
  return (value + delta) % 1000003;
}

function benchmarkDirectCalls(jobs, lane) {
  // Copy the callee once per lane so shared-realm rows measure ordinary call
  // throughput rather than contending on the benchmark's own global binding.
  var step = benchmarkDirectCallStep;
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var value = lane + job + 1;
    for (var i = 0; i < 10000; i = i + 1)
      value = step(value, i);
    total = total + value;
  }
  return total;
}

function benchmarkMethodStep(value, delta) {
  return (this.bias + value + delta) % 1000003;
}

function benchmarkMethodCalls(jobs, lane) {
  // Each lane owns its receiver. The method reads `this.bias`, so this remains
  // a real property lookup and receiver-binding call rather than a direct call
  // with decorative object syntax.
  var receiver = { bias: lane + 1, step: benchmarkMethodStep };
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var value = job + 1;
    for (var i = 0; i < 10000; i = i + 1)
      value = receiver.step(value, i);
    total = total + value;
  }
  return total;
}

var benchmarkFibValue = function benchmarkFibValue(n, state) {
  // Keep each call observable so this row continues measuring recursive call
  // throughput even when an engine can recognize and memoize the pure
  // recurrence. The state is invocation-local, so shared-realm lanes never
  // race one counter or produce schedule-dependent checksums.
  state.calls = state.calls + 1;
  return n < 2 ? n : benchmarkFibValue(n - 1, state) + benchmarkFibValue(n - 2, state);
};

function benchmarkFibonacci(jobs, lane) {
  var total = lane;
  var state = { calls: 0 };
  for (var job = 0; job < jobs; job = job + 1)
    total = total + benchmarkFibValue(24, state);
  return total + state.calls;
}

function benchmarkFunction(name) {
  if (name === "arithmetic") return benchmarkArithmetic;
  if (name === "properties") return benchmarkProperties;
  if (name === "arrays") return benchmarkArrays;
  if (name === "direct_calls") return benchmarkDirectCalls;
  if (name === "method_calls") return benchmarkMethodCalls;
  if (name === "fibonacci") return benchmarkFibonacci;
  throw new Error("unknown benchmark workload: " + name);
}

function runBenchmark(name, jobs, lane) {
  return benchmarkFunction(name)(jobs, lane);
}
