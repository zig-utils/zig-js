// Representative application-shaped workloads shared byte-for-byte by zig-js
// and JavaScriptCore. This source is separate from comparison.js so extending
// the representative matrix never changes the original panel's cold parse cost.
//
// Every workload returns an exactly representable integer derived from all
// performed work. A paired `_variant` row changes names, layout, data shape,
// and traversal order without changing the semantic surface being measured.

var representativeCorpus = [
  "Crème brûlée and Καλημέρα κόσμε",
  "東京からSão Pauloへ — naïve façade",
  "mañana, déjà vu, and coöperate",
  "emoji: 😀🚀🧪; combining: é"
];

function representativeStrings(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var value = representativeCorpus[(job + lane + variant) & 3];
    for (var i = 0; i < 160; i = i + 1) {
      var pivot = (i * 7 + lane + variant) % value.length;
      var left = value.slice(pivot);
      var right = value.slice(0, pivot);
      value = variant ? (right + ":" + left) : (left + ":" + right);
      if (value.length > 96) value = value.slice(1, 81);
      total = total + value.charCodeAt((i + job) % value.length);
    }
    total = total + value.length;
  }
  return total;
}

function representativeRegExp(jobs, lane, variant) {
  var total = 0;
  var input = variant
    ? "id=418; state=ready; id=73; state=waiting; id=905; state=done"
    : "user-418:ready user-73:waiting user-905:done";
  var expression = variant
    ? /id=(\d+);\s+state=([a-z]+)/g
    : /user-(\d+):([a-z]+)/g;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 180; i = i + 1) {
      expression.lastIndex = 0;
      var match;
      while ((match = expression.exec(input)) !== null)
        total = total + Number(match[1]) + match[2].length + lane + (job & 3);
    }
  }
  return total;
}

function representativeJson(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var record = variant
      ? { meta: { lane: lane, active: true }, values: [job, job + 1, job + 2], name: "row-" + job }
      : { name: "row-" + job, values: [job, job + 1, job + 2], meta: { active: true, lane: lane } };
    for (var i = 0; i < 90; i = i + 1) {
      var encoded = JSON.stringify(record);
      record = JSON.parse(encoded);
      record.values[i % 3] = (record.values[i % 3] + i + lane) & 65535;
      total = total + encoded.length + record.values[i % 3];
    }
  }
  return total;
}

function representativeCollections(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var map = new Map();
    var set = new Set();
    for (var i = 0; i < 512; i = i + 1) {
      var key = variant ? "key:" + ((i * 17) & 511) : "key:" + i;
      var value = (i + job + lane) & 65535;
      map.set(key, value);
      set.add(key);
    }
    map.forEach(function (value, key) {
      if (set.has(key)) total = total + value + key.length;
    });
    for (var remove = variant; remove < 512; remove = remove + 2)
      total = total + (map.delete("key:" + remove) ? 1 : 0);
  }
  return total;
}

function representativeWeakCollections(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var weakMap = new WeakMap();
    var weakSet = new WeakSet();
    var live = [];
    for (var i = 0; i < 384; i = i + 1) {
      var key = variant ? { index: i, pad: i & 7 } : { pad: i & 7, index: i };
      weakMap.set(key, i + job + lane);
      weakSet.add(key);
      if ((i & 3) === 0) live.push(key);
      total = total + weakMap.get(key) + (weakSet.has(key) ? 1 : 0);
    }
    for (var keep = live.length - 1; keep >= 0; keep = keep - 1)
      total = total + weakMap.get(live[keep]);
  }
  return total;
}

function representativeTypedData(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var buffer = new ArrayBuffer(4096);
    var words = new Uint32Array(buffer);
    var view = new DataView(buffer);
    for (var i = 0; i < words.length; i = i + 1)
      words[i] = (i * 2654435761 + job + lane) >>> 0;
    for (var pass = 0; pass < 24; pass = pass + 1) {
      if (variant) {
        for (var back = words.length - 1; back >= 0; back = back - 1) {
          var reverseValue = view.getUint32(back * 4, true);
          view.setUint32(back * 4, (reverseValue + pass + back) >>> 0, true);
          total = total + (reverseValue & 1023);
        }
      } else {
        for (var forward = 0; forward < words.length; forward = forward + 1) {
          var value = view.getUint32(forward * 4, true);
          view.setUint32(forward * 4, (value + pass + forward) >>> 0, true);
          total = total + (value & 1023);
        }
      }
    }
  }
  return total;
}

class RepresentativeCounter {
  #value;

  constructor(seed) {
    this.#value = seed;
  }

  advance(delta) {
    this.#value = (this.#value + delta) % 1000003;
    return this.#value;
  }
}

function representativeClasses(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var counter = new RepresentativeCounter(lane + job + variant);
    for (var i = 0; i < 12000; i = i + 1)
      total = total + (counter.advance(variant ? i ^ 3 : i) & 255);
  }
  return total;
}

function* representativeSequence(seed, variant) {
  var value = seed;
  for (var i = 0; i < 512; i = i + 1) {
    value = (value + (variant ? (i * 3 + 1) : (i + 1))) % 1000003;
    yield value;
  }
}

function representativeIterators(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var sequence = representativeSequence(job + lane, variant);
    for (var step = sequence.next(); !step.done; step = sequence.next())
      total = total + (step.value & 1023);
  }
  return total;
}

function representativeProxyAccessors(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var state = { value: lane + job, reads: 0, writes: 0 };
    var target = {};
    Object.defineProperty(target, "current", {
      get: function () { state.reads = state.reads + 1; return state.value; },
      set: function (value) { state.writes = state.writes + 1; state.value = value; }
    });
    var proxy = new Proxy(target, {
      get: function (object, key, receiver) {
        return Reflect.get(object, key, receiver);
      },
      set: function (object, key, value, receiver) {
        return Reflect.set(object, key, value, receiver);
      }
    });
    for (var i = 0; i < 5000; i = i + 1) {
      var next = (proxy.current + (variant ? i * 3 : i)) % 1000003;
      proxy.current = next;
      total = total + (next & 255);
    }
    total = total + state.reads + state.writes;
  }
  return total;
}

function representativeIntl(jobs, lane, variant) {
  var total = 0;
  var formatter = variant
    ? new Intl.NumberFormat("de-DE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    : new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 240; i = i + 1) {
      var output = formatter.format((job + 1) * 1000 + i + lane / 10);
      total = total + output.length + output.charCodeAt(0);
    }
  }
  return total;
}

function representativeLongLivedGraph(jobs, lane, variant) {
  var nodes = [];
  var total = 0;
  for (var i = 0; i < 2048; i = i + 1)
    nodes.push({ value: i + lane, left: null, right: null, payload: [i & 255, (i * 3) & 255] });
  for (var link = 1; link < nodes.length; link = link + 1) {
    var parent = nodes[(link - 1) >> 1];
    if (link & 1) parent.left = nodes[link]; else parent.right = nodes[link];
  }
  for (var job = 0; job < jobs; job = job + 1) {
    var stride = variant ? 31 : 17;
    for (var visit = 0; visit < nodes.length; visit = visit + 1) {
      var index = (visit * stride) & 2047;
      var node = nodes[index];
      node.value = (node.value + job + visit) & 65535;
      total = total + node.value + node.payload[(visit + variant) & 1];
    }
  }
  return total;
}

function representativeApplicationMix(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var input = '{"name":"item-' + job + '","tags":["hot","ready"],"value":' + (job + lane) + '}';
    var record = JSON.parse(input);
    var matcher = variant ? /item-(\d+)/ : /([a-z]+)-(\d+)/;
    var match = matcher.exec(record.name);
    var index = new Map();
    index.set(record.name, record);
    var queue = [record];
    for (var i = 0; i < 256; i = i + 1) {
      var current = queue[i & (queue.length - 1)];
      var next = { name: current.name + ":" + i, value: current.value + i, tags: current.tags.slice() };
      if (queue.length < 256) queue.push(next); else queue[i & 255] = next;
      index.set(next.name, next);
      total = total + next.value + next.tags.length;
    }
    total = total + Number(match[variant ? 1 : 2]) + index.size;
  }
  return total;
}

function benchmarkFunction(name) {
  if (name === "representative_strings") return function (jobs, lane) { return representativeStrings(jobs, lane, 0); };
  if (name === "representative_strings_variant") return function (jobs, lane) { return representativeStrings(jobs, lane, 1); };
  if (name === "representative_regexp") return function (jobs, lane) { return representativeRegExp(jobs, lane, 0); };
  if (name === "representative_regexp_variant") return function (jobs, lane) { return representativeRegExp(jobs, lane, 1); };
  if (name === "representative_json") return function (jobs, lane) { return representativeJson(jobs, lane, 0); };
  if (name === "representative_json_variant") return function (jobs, lane) { return representativeJson(jobs, lane, 1); };
  if (name === "representative_collections") return function (jobs, lane) { return representativeCollections(jobs, lane, 0); };
  if (name === "representative_collections_variant") return function (jobs, lane) { return representativeCollections(jobs, lane, 1); };
  if (name === "representative_weak_collections") return function (jobs, lane) { return representativeWeakCollections(jobs, lane, 0); };
  if (name === "representative_weak_collections_variant") return function (jobs, lane) { return representativeWeakCollections(jobs, lane, 1); };
  if (name === "representative_typed_data") return function (jobs, lane) { return representativeTypedData(jobs, lane, 0); };
  if (name === "representative_typed_data_variant") return function (jobs, lane) { return representativeTypedData(jobs, lane, 1); };
  if (name === "representative_classes") return function (jobs, lane) { return representativeClasses(jobs, lane, 0); };
  if (name === "representative_classes_variant") return function (jobs, lane) { return representativeClasses(jobs, lane, 1); };
  if (name === "representative_iterators") return function (jobs, lane) { return representativeIterators(jobs, lane, 0); };
  if (name === "representative_iterators_variant") return function (jobs, lane) { return representativeIterators(jobs, lane, 1); };
  if (name === "representative_proxy_accessors") return function (jobs, lane) { return representativeProxyAccessors(jobs, lane, 0); };
  if (name === "representative_proxy_accessors_variant") return function (jobs, lane) { return representativeProxyAccessors(jobs, lane, 1); };
  if (name === "representative_intl") return function (jobs, lane) { return representativeIntl(jobs, lane, 0); };
  if (name === "representative_intl_variant") return function (jobs, lane) { return representativeIntl(jobs, lane, 1); };
  if (name === "representative_long_lived_graph") return function (jobs, lane) { return representativeLongLivedGraph(jobs, lane, 0); };
  if (name === "representative_long_lived_graph_variant") return function (jobs, lane) { return representativeLongLivedGraph(jobs, lane, 1); };
  if (name === "representative_application_mix") return function (jobs, lane) { return representativeApplicationMix(jobs, lane, 0); };
  if (name === "representative_application_mix_variant") return function (jobs, lane) { return representativeApplicationMix(jobs, lane, 1); };
  throw new Error("unknown representative benchmark workload: " + name);
}

function runBenchmark(name, jobs, lane) {
  return benchmarkFunction(name)(jobs, lane);
}
