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

// Valid wide strict parameter lists keep the timed boundary on frontend parsing
// and compilation. Sources are created lazily during the runner warmup, so the
// scored steady-state row does not measure string construction and unrelated
// workloads do not pay for it. Every name is unique; duplicate-name and
// reserved-name rejection stay semantic tests.
var representativeStrictParamsSelectedSource = "";
function selectRepresentativeStrictParams(width) {
  var chunks = ["(function strictWidth("];
  for (var parameter = 0; parameter < width; parameter = parameter + 1)
    chunks.push((parameter === 0 ? "" : ",") + "parameter" + parameter);
  chunks.push("){\"use strict\";return 7;})");
  representativeStrictParamsSelectedSource = chunks.join("");
  return representativeFrontendStrictParams;
}

function representativeFrontendStrictParams(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var parsed = eval(representativeStrictParamsSelectedSource);
    total = total + parsed.length + parsed() + lane;
  }
  return total;
}

// Own-key fixtures are selected before warmup so the timed rows isolate
// enumeration and Proxy invariant work. The ordered fixture adds one accessor,
// which activates the exact cross-storage creation-order list without paying
// unrelated deletion/rebuild cost during setup.
var representativeOwnKeysSelected = null;
function selectRepresentativeOwnKeys(kind, width) {
  var target = kind === "array" ? [] : {};
  for (var index = 0; index < width; index = index + 1) {
    if (kind === "array") {
      target[index * 2] = index;
      target["field-" + index] = index;
    } else {
      target["field-" + index] = index;
    }
  }
  if (kind === "ordered")
    Object.defineProperty(target, "accessor", {
      get: function () { return width; },
      enumerable: true,
      configurable: true
    });
  if (kind === "proxy") {
    var trapKeys = Reflect.ownKeys(target);
    Object.preventExtensions(target);
    target = new Proxy(target, {
      ownKeys: function () { return trapKeys; }
    });
  }
  representativeOwnKeysSelected = target;
  return representativeOwnKeys;
}

function representativeOwnKeys(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var keys = Reflect.ownKeys(representativeOwnKeysSelected);
    var first = keys[0];
    var last = keys[keys.length - 1];
    total = total + keys.length + first.length + last.length +
      first.charCodeAt(0) + last.charCodeAt(last.length - 1) + lane;
  }
  return total;
}

// Named deletion grows one immutable fixture before warmup, then deletes a
// different middle key on every invocation. That keeps construction outside
// the timed boundary while every warmup/sample still pays one real deletion.
// The re-add variant restores the deleted key with non-default attributes and
// verifies that its new creation position is the end of the string-key order.
var representativeNamedDeleteTarget = null;
var representativeNamedDeleteWidth = 0;
var representativeNamedDeleteCursor = 0;
var representativeNamedDeleteReadd = false;
function selectRepresentativeNamedDelete(width, readd) {
  var target = {};
  for (var index = 0; index < width; index = index + 1)
    target["field-" + index] = index;
  representativeNamedDeleteTarget = target;
  representativeNamedDeleteWidth = width;
  representativeNamedDeleteCursor = 0;
  representativeNamedDeleteReadd = readd;
  return representativeNamedDelete;
}

function representativeNamedDelete(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var index = (representativeNamedDeleteWidth >> 1) + representativeNamedDeleteCursor;
    representativeNamedDeleteCursor = representativeNamedDeleteCursor + 1;
    var key = "field-" + index;
    var before = Object.getOwnPropertyDescriptor(representativeNamedDeleteTarget, key);
    var deleted = delete representativeNamedDeleteTarget[key];
    var absent = !Object.prototype.hasOwnProperty.call(representativeNamedDeleteTarget, key);
    var keys;
    var descriptorExact = before.value === index && before.writable && before.enumerable && before.configurable;
    if (representativeNamedDeleteReadd) {
      Object.defineProperty(representativeNamedDeleteTarget, key, {
        value: index + 1,
        writable: false,
        enumerable: false,
        configurable: true
      });
      keys = Reflect.ownKeys(representativeNamedDeleteTarget);
      var after = Object.getOwnPropertyDescriptor(representativeNamedDeleteTarget, key);
      descriptorExact = descriptorExact && after.value === index + 1 &&
        !after.writable && !after.enumerable && after.configurable;
    } else {
      keys = Reflect.ownKeys(representativeNamedDeleteTarget);
    }
    var orderExact = keys[0] === "field-0" &&
      keys[keys.length - 1] === (representativeNamedDeleteReadd ? key : "field-" + (representativeNamedDeleteWidth - 1));
    total = total + keys.length + key.length + keys[0].length + keys[keys.length - 1].length +
      (deleted ? 100000 : 0) + (absent ? 200000 : 0) +
      (descriptorExact ? 400000 : 0) + (orderExact ? 800000 : 0) + lane;
  }
  return total;
}

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

// Callback-observable JSON.parse source metadata. A wide primitive array makes
// per-property metadata lookup cost visible without conflating the row with
// nesting limits or user callback work.
function representativeJsonReviverSource(jobs, lane) {
  var width = 8192;
  var chunks = ["["];
  for (var i = 0; i < width; i = i + 1)
    chunks.push((i === 0 ? "" : ",") + String(i + lane));
  chunks.push("]");
  var encoded = chunks.join("");
  var total = 0;
  function sourceReviver(key, current, context) {
    if (key !== "") {
      if (context.source === undefined) throw new Error("missing JSON source context");
      total = total + current + context.source.length;
    }
    return current;
  }
  for (var job = 0; job < jobs; job = job + 1) {
    var parsed = JSON.parse(encoded, sourceReviver);
    total = total + parsed.length + parsed[(job * 17 + lane) & (width - 1)];
  }
  return total;
}

// Escaped JSON strings exercise the owned decoding path. The three suffixes
// cover ordinary escapes, a lone UTF-16 surrogate represented as WTF-8, and
// repeated Unicode escapes without letting one fixed spelling dominate.
function representativeJsonEscapedStrings(jobs, lane) {
  var width = 1024;
  var chunks = ["["];
  for (var i = 0; i < width; i = i + 1) {
    var suffix = i % 3 === 0 ? "\\n\\t\\u263a" :
      (i % 3 === 1 ? "\\r\\b\\f\\ud834" : "\\u0061\\u0062\\u0063");
    chunks.push((i === 0 ? "" : ",") + "\"row-" + (i + lane) + suffix + "-tail\"");
  }
  chunks.push("]");
  var encoded = chunks.join("");
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var parsed = JSON.parse(encoded);
    for (var index = 0; index < parsed.length; index = index + 1) {
      var text = parsed[index];
      total = total + text.length + text.charCodeAt(0) + text.charCodeAt(text.length - 1);
    }
  }
  return total;
}

// A wide callback-observable PropertyList isolates replacer-array membership
// and first-occurrence ordering from JSON nesting and parse costs.
function representativeJsonStringifyReplacer(jobs, lane) {
  var width = 4096;
  var record = {};
  var replacer = [];
  for (var i = 0; i < width; i = i + 1) {
    var index = (i * 17) & (width - 1);
    var key = "field-" + index;
    record[key] = index + lane;
    replacer.push(key);
  }
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var encoded = JSON.stringify(record, replacer);
    total = total + encoded.length + encoded.charCodeAt(0) +
      encoded.charCodeAt(encoded.length - 1) + encoded.indexOf("field-0");
  }
  return total;
}

// Isolate PropertyList membership from object construction/property lookup.
// JSON.stringify must still consume and deduplicate the complete replacer even
// when the serialized object has no matching properties.
function representativeJsonStringifyReplacerMembership(jobs, lane) {
  var width = 16384;
  var replacer = [];
  for (var i = 0; i < width; i = i + 1)
    replacer.push("field-" + ((i * 17 + lane) & (width - 1)));
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var encoded = JSON.stringify({}, replacer);
    total = total + encoded.length + replacer.length +
      replacer[0].length + replacer[replacer.length - 1].length;
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

function representativeStrongIdentityCollections(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var map = new Map();
    var set = new Set();
    var objects = [];
    var symbols = [];
    for (var i = 0; i < 256; i = i + 1) {
      var object = variant ? { pad: i & 7, index: i } : { index: i, pad: i & 7 };
      var symbol = Symbol("identity:" + (variant ? ((i * 17) & 255) : i));
      var value = (i + job + lane) & 65535;
      objects.push(object);
      symbols.push(symbol);
      map.set(object, value);
      map.set(symbol, value + 1);
      set.add(object);
      set.add(symbol);
    }
    for (var lookup = 0; lookup < 256; lookup = lookup + 1) {
      var index = variant ? 255 - lookup : lookup;
      total = total + map.get(objects[index]) + map.get(symbols[index]);
      total = total + (set.has(objects[index]) ? 1 : 0) + (set.has(symbols[index]) ? 1 : 0);
    }
    for (var remove = 0; remove < 256; remove = remove + 2) {
      total = total + (map.delete(objects[remove]) ? 1 : 0) + (map.delete(symbols[remove]) ? 1 : 0);
      total = total + (set.delete(objects[remove]) ? 1 : 0) + (set.delete(symbols[remove]) ? 1 : 0);
    }
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

// Keep every weak key strongly reachable through this fixture, then let the
// zig-js runner compact the precise heap between warmup and scored invocation.
// Mixed ordinary-object and non-registered-Symbol keys cover both weak-key
// kinds. The untouched control row uses the identical setup without movement.
var representativeWeakLookupSelected = null;
function selectRepresentativeWeakLookup(width) {
  // Create an unreachable prefix before the live fixture so explicit
  // compaction has real holes to fill instead of returning no_candidates.
  var dead = [];
  for (var garbage = 0; garbage < width; garbage = garbage + 1)
    dead.push({ garbage: garbage, pad: garbage & 7 });
  dead = null;

  var weakMap = new WeakMap();
  var weakSet = new WeakSet();
  var keys = [];
  for (var index = 0; index < width; index = index + 1) {
    var key = (index & 1) === 0
      ? { index: index, pad: index & 7 }
      : Symbol("weak-identity:" + index);
    keys.push(key);
    weakMap.set(key, index * 3 + 7);
    weakSet.add(key);
  }
  representativeWeakLookupSelected = {
    weakMap: weakMap,
    weakSet: weakSet,
    keys: keys,
    missObject: { miss: true },
    missSymbol: Symbol("weak-identity:miss")
  };
  return representativeWeakLookup;
}

function representativeWeakLookup(jobs, lane) {
  var total = 0;
  var selected = representativeWeakLookupSelected;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var lookup = selected.keys.length - 1; lookup >= 0; lookup = lookup - 1) {
      var key = selected.keys[lookup];
      total = total + selected.weakMap.get(key) +
        (selected.weakMap.has(key) ? 1 : 0) +
        (selected.weakSet.has(key) ? 2 : 0);
    }
    total = total +
      (selected.weakMap.get(selected.missObject) === undefined ? 100 : 0) +
      (!selected.weakMap.has(selected.missSymbol) ? 200 : 0) +
      (!selected.weakSet.has(selected.missObject) ? 400 : 0) + lane;
  }
  return total;
}

// Exercise Date's widest setter signature at deterministic 1K/2K/4K widths.
// The setTime control performs the identical timestamp mutation and checksum
// without entering the generic component-setter argument-copy path.
function selectRepresentativeDateSetter(width, control) {
  return function (jobs, lane) {
    var total = 0;
    for (var job = 0; job < jobs; job = job + 1) {
      var date = new Date(0);
      for (var index = 0; index < width; index = index + 1) {
        var hour = (index + job + lane) % 24;
        var minute = (index * 3 + lane) % 60;
        var second = (index * 7 + job) % 60;
        var millisecond = (index * 17 + job + lane) % 1000;
        var timestamp = control
          ? date.setTime(hour * 3600000 + minute * 60000 + second * 1000 + millisecond)
          : date.setUTCHours(hour, minute, second, millisecond);
        total = total + (timestamp % 1000003) + date.getUTCMilliseconds();
      }
    }
    return total;
  };
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

var representativeAsyncStates = [];

function representativeAsyncPrepare(jobs, lanes, lane, shared) {
  representativeAsyncStates = [];
  var count = shared ? lanes : lane + 1;
  for (var index = 0; index < count; index = index + 1)
    representativeAsyncStates.push({ total: 0 });
}

function representativeAsyncChecksum(jobs, lanes, lane, shared) {
  var total = 0;
  if (shared) {
    for (var index = 0; index < lanes; index = index + 1)
      total = total + representativeAsyncStates[index].total;
  } else {
    total = representativeAsyncStates[lane].total;
  }
  return total;
}

function representativeDirectReaction(cell, seed) {
  Promise.resolve().then(function () {
    cell.total = cell.total + (seed & 255);
  });
}

function representativePromiseChain(cell, seed) {
  Promise.resolve(seed).then(function (value) {
    return value + 3;
  }).then(function (value) {
    cell.total = cell.total + (value & 511);
  });
}

async function representativeAsyncContinuation(cell, seed) {
  var value = await Promise.resolve(seed);
  value = await Promise.resolve(value + 7);
  cell.total = cell.total + (value & 1023);
}

function representativeThenable(cell, seed) {
  Promise.resolve({
    then: function (resolve) { resolve(seed + 11); }
  }).then(function (value) {
    cell.total = cell.total + (value & 2047);
  });
}

function representativeAsyncWork(jobs, lane, variant) {
  var cell = representativeAsyncStates[lane];
  for (var job = 0; job < jobs; job = job + 1) {
    var seed = job * 17 + lane * 29 + 1;
    if (variant) {
      representativeThenable(cell, seed);
      representativeAsyncContinuation(cell, seed);
      representativePromiseChain(cell, seed);
      representativeDirectReaction(cell, seed);
    } else {
      representativeDirectReaction(cell, seed);
      representativePromiseChain(cell, seed);
      representativeAsyncContinuation(cell, seed);
      representativeThenable(cell, seed);
    }
  }
  return 0;
}

function representativeSelectAsync(variant) {
  globalThis.__benchmarkPrepare = representativeAsyncPrepare;
  globalThis.__benchmarkFinish = representativeAsyncChecksum;
  globalThis.__benchmarkReadChecksum = representativeAsyncChecksum;
  return function (jobs, lane) { return representativeAsyncWork(jobs, lane, variant); };
}

function representativeTemporalForward(job, lane) {
  var date = new Temporal.PlainDate(2024 + (job & 3), 1 + (lane % 12), 1 + (job % 20));
  var instant = Temporal.Instant.from("2024-01-01T00:00:00Z");
  for (var step = 0; step < 48; step = step + 1) {
    var delta = (step % 7) + 1;
    date = date.add({ days: delta });
    instant = instant.add({ milliseconds: delta * 13 });
  }
  var duration = Temporal.Duration.from({ hours: 3, minutes: 17, seconds: lane + (job & 7) });
  return date.year * 1000000 + date.month * 10000 + date.day * 100 +
    (instant.epochMilliseconds % 1000000) + duration.total({ unit: "seconds" });
}

function representativeTemporalReverse(job, lane) {
  var calendarDate = new Temporal.PlainDate(2024 + (job & 3), 1 + (lane % 12), 1 + (job % 20));
  var timelinePoint = Temporal.Instant.from("2024-01-01T00:00:00Z");
  for (var cursor = 47; cursor >= 0; cursor = cursor - 1) {
    var increment = (cursor % 7) + 1;
    timelinePoint = timelinePoint.add({ milliseconds: increment * 13 });
    calendarDate = calendarDate.add({ days: increment });
  }
  var span = Temporal.Duration.from({ seconds: lane + (job & 7), minutes: 17, hours: 3 });
  return calendarDate.year * 1000000 + calendarDate.month * 10000 + calendarDate.day * 100 +
    (timelinePoint.epochMilliseconds % 1000000) + span.total({ unit: "seconds" });
}

function representativeTemporal(jobs, lane, variant) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1)
    total = total + (variant ? representativeTemporalReverse(job, lane) : representativeTemporalForward(job, lane));
  return total;
}

function representativeTemporalAvailability() {
  return typeof Temporal === "object" &&
    typeof Temporal.PlainDate === "function" &&
    typeof Temporal.Instant === "function" &&
    typeof Temporal.Duration === "function" ? 1 : 0;
}

function representativeModulePublicProbe() {
  return eval("import { value } from './dependency.js'; value;");
}

function benchmarkFunction(name) {
  if (name === "representative_frontend_strict_params_1024") return selectRepresentativeStrictParams(1024);
  if (name === "representative_frontend_strict_params_2048") return selectRepresentativeStrictParams(2048);
  if (name === "representative_frontend_strict_params_4096") return selectRepresentativeStrictParams(4096);
  if (name === "representative_own_keys_ordered_1024") return selectRepresentativeOwnKeys("ordered", 1024);
  if (name === "representative_own_keys_ordered_2048") return selectRepresentativeOwnKeys("ordered", 2048);
  if (name === "representative_own_keys_ordered_4096") return selectRepresentativeOwnKeys("ordered", 4096);
  if (name === "representative_own_keys_sparse_array") return selectRepresentativeOwnKeys("array", 2048);
  if (name === "representative_own_keys_proxy_invariants") return selectRepresentativeOwnKeys("proxy", 2048);
  if (name === "representative_named_delete_1024") return selectRepresentativeNamedDelete(1024, false);
  if (name === "representative_named_delete_2048") return selectRepresentativeNamedDelete(2048, false);
  if (name === "representative_named_delete_4096") return selectRepresentativeNamedDelete(4096, false);
  if (name === "representative_named_delete_readd_1024") return selectRepresentativeNamedDelete(1024, true);
  if (name === "representative_named_delete_readd_2048") return selectRepresentativeNamedDelete(2048, true);
  if (name === "representative_named_delete_readd_4096") return selectRepresentativeNamedDelete(4096, true);
  if (name === "representative_strings") return function (jobs, lane) { return representativeStrings(jobs, lane, 0); };
  if (name === "representative_strings_variant") return function (jobs, lane) { return representativeStrings(jobs, lane, 1); };
  if (name === "representative_regexp") return function (jobs, lane) { return representativeRegExp(jobs, lane, 0); };
  if (name === "representative_regexp_variant") return function (jobs, lane) { return representativeRegExp(jobs, lane, 1); };
  if (name === "representative_json") return function (jobs, lane) { return representativeJson(jobs, lane, 0); };
  if (name === "representative_json_variant") return function (jobs, lane) { return representativeJson(jobs, lane, 1); };
  if (name === "representative_json_reviver_source") return representativeJsonReviverSource;
  if (name === "representative_json_escaped_strings") return representativeJsonEscapedStrings;
  if (name === "representative_json_stringify_replacer") return representativeJsonStringifyReplacer;
  if (name === "representative_json_stringify_replacer_membership") return representativeJsonStringifyReplacerMembership;
  if (name === "representative_collections") return function (jobs, lane) { return representativeCollections(jobs, lane, 0); };
  if (name === "representative_collections_variant") return function (jobs, lane) { return representativeCollections(jobs, lane, 1); };
  if (name === "representative_strong_identity_collections") return function (jobs, lane) { return representativeStrongIdentityCollections(jobs, lane, 0); };
  if (name === "representative_strong_identity_collections_variant") return function (jobs, lane) { return representativeStrongIdentityCollections(jobs, lane, 1); };
  if (name === "representative_weak_collections") return function (jobs, lane) { return representativeWeakCollections(jobs, lane, 0); };
  if (name === "representative_weak_collections_variant") return function (jobs, lane) { return representativeWeakCollections(jobs, lane, 1); };
  if (name === "representative_weak_post_compact_1024") return selectRepresentativeWeakLookup(1024);
  if (name === "representative_weak_post_compact_2048") return selectRepresentativeWeakLookup(2048);
  if (name === "representative_weak_post_compact_4096") return selectRepresentativeWeakLookup(4096);
  if (name === "representative_weak_lookup_control_4096") return selectRepresentativeWeakLookup(4096);
  if (name === "representative_date_setter_1024") return selectRepresentativeDateSetter(1024, false);
  if (name === "representative_date_setter_2048") return selectRepresentativeDateSetter(2048, false);
  if (name === "representative_date_setter_4096") return selectRepresentativeDateSetter(4096, false);
  if (name === "representative_date_settime_control_4096") return selectRepresentativeDateSetter(4096, true);
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
  if (name === "representative_async_microtasks") return representativeSelectAsync(0);
  if (name === "representative_async_microtasks_variant") return representativeSelectAsync(1);
  if (name === "representative_temporal") return function (jobs, lane) { return representativeTemporal(jobs, lane, 0); };
  if (name === "representative_temporal_variant") return function (jobs, lane) { return representativeTemporal(jobs, lane, 1); };
  if (name === "representative_temporal_availability") return function () { return representativeTemporalAvailability(); };
  if (name === "representative_module_public_probe") return function () { return representativeModulePublicProbe(); };
  throw new Error("unknown representative benchmark workload: " + name);
}

function runBenchmark(name, jobs, lane) {
  return benchmarkFunction(name)(jobs, lane);
}
