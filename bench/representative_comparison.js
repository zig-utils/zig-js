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

var representativeRegExpSearchAscii = "";
var representativeRegExpSearchBmp = "";
var representativeRegExpSearchAstral = "";
var representativeRegExpSearchLone = "";
for (var representativeRegExpSearchIndex = 0; representativeRegExpSearchIndex < 64; representativeRegExpSearchIndex = representativeRegExpSearchIndex + 1) {
  var representativeRegExpSearchSuffix = "row-" + (representativeRegExpSearchIndex % 10) + ";";
  representativeRegExpSearchAscii = representativeRegExpSearchAscii + "plain-" + representativeRegExpSearchSuffix;
  representativeRegExpSearchBmp = representativeRegExpSearchBmp + "café水-" + representativeRegExpSearchSuffix;
  representativeRegExpSearchAstral = representativeRegExpSearchAstral + "emoji😀-" + representativeRegExpSearchSuffix;
  representativeRegExpSearchLone = representativeRegExpSearchLone + "lone\ud800x-" + representativeRegExpSearchSuffix;
}

function representativeRegExpSearchInput(jobs, lane, kind) {
  var input = kind === "bmp" ? representativeRegExpSearchBmp :
    (kind === "astral" ? representativeRegExpSearchAstral :
      (kind === "lone" ? representativeRegExpSearchLone : representativeRegExpSearchAscii));
  var expression = /row-(\d+);/g;
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var round = 0; round < 12; round = round + 1) {
      expression.lastIndex = 0;
      var match;
      while ((match = expression.exec(input)) !== null)
        total = total + match.index + Number(match[1]) + lane + (job & 3);
    }
  }
  return total + input.length;
}

var representativeTextEncoderAscii = "";
var representativeTextEncoderUnicode = "";
var representativeTextEncoderLone = "";
var representativeTextEncoderPair = "";
for (var representativeTextEncoderIndex = 0; representativeTextEncoderIndex < 256; representativeTextEncoderIndex = representativeTextEncoderIndex + 1) {
  var representativeTextEncoderSuffix = "-row-" + (representativeTextEncoderIndex % 10) + ";";
  representativeTextEncoderAscii = representativeTextEncoderAscii + "plain" + representativeTextEncoderSuffix;
  representativeTextEncoderUnicode = representativeTextEncoderUnicode + "café水😀" + representativeTextEncoderSuffix;
  representativeTextEncoderLone = representativeTextEncoderLone + "lone\ud800x" + representativeTextEncoderSuffix;
  representativeTextEncoderPair = representativeTextEncoderPair + "pair\ud83d\ude00" + representativeTextEncoderSuffix;
}

function representativeTextEncoderBoundary(jobs, lane, kind) {
  var input = kind === "unicode" ? representativeTextEncoderUnicode :
    (kind === "lone" ? representativeTextEncoderLone :
      (kind === "pair" ? representativeTextEncoderPair : representativeTextEncoderAscii));
  var encoder = new TextEncoder();
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var round = 0; round < 64; round = round + 1) {
      var bytes = encoder.encode(input);
      total = total + bytes.length + bytes[0] + bytes[Math.floor(bytes.length / 2)] +
        bytes[bytes.length - 1] + lane + (job & 3);
    }
  }
  return total + input.length;
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

// JSON.stringify's cycle rule is active-ancestor membership, not global graph
// visitation. Selection constructs the graph once before all ten warmups and
// the scored invocation; every job performs and validates a real stringify.
var representativeJsonStringifyGraph = null;
var representativeJsonStringifyDepth = 0;
var representativeJsonStringifyExpectedLength = 0;
var representativeJsonStringifyExpectedLeafOffset = 0;
function selectRepresentativeJsonStringifyDepth(depth, circular) {
  var leaf = { leaf: 1 };
  var root = leaf;
  for (var level = 1; level < depth; level = level + 1)
    root = { next: root };
  if (circular) leaf.next = root;
  representativeJsonStringifyGraph = root;
  representativeJsonStringifyDepth = depth;
  representativeJsonStringifyExpectedLength = depth * 9 + 1;
  representativeJsonStringifyExpectedLeafOffset = (depth - 1) * 8 + 1;
  return circular ? representativeJsonStringifyCycle : representativeJsonStringifyAcyclic;
}

function representativeJsonStringifyAcyclic(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var encoded = JSON.stringify(representativeJsonStringifyGraph);
    var leafOffset = encoded.indexOf("\"leaf\":1");
    if (encoded.length !== representativeJsonStringifyExpectedLength ||
        leafOffset !== representativeJsonStringifyExpectedLeafOffset ||
        encoded.charCodeAt(0) !== 123 || encoded.charCodeAt(encoded.length - 1) !== 125)
      throw new Error("JSON.stringify depth witness drift");
    total = total + encoded.length + leafOffset +
      encoded.charCodeAt(0) + encoded.charCodeAt(encoded.length - 1) + lane;
  }
  return total;
}

function representativeJsonStringifyCycle(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var threw = false;
    try {
      JSON.stringify(representativeJsonStringifyGraph);
    } catch (error) {
      if (!(error instanceof TypeError)) throw error;
      threw = true;
    }
    if (!threw) throw new Error("JSON.stringify accepted an ancestor cycle");
    total = total + 1000000 + representativeJsonStringifyDepth + lane;
  }
  return total;
}

function selectRepresentativeJsonStringifyShallow(width) {
  var siblings = [];
  var shared = { leaf: 1 };
  for (var index = 0; index < width; index = index + 1)
    siblings.push(shared);
  representativeJsonStringifyGraph = siblings;
  representativeJsonStringifyDepth = width;
  representativeJsonStringifyExpectedLength = width * 11 + 1;
  representativeJsonStringifyExpectedLeafOffset = 2;
  return representativeJsonStringifyShallow;
}

function representativeJsonStringifyShallow(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var encoded = JSON.stringify(representativeJsonStringifyGraph);
    var leafOffset = encoded.indexOf("\"leaf\":1");
    if (encoded.length !== representativeJsonStringifyExpectedLength ||
        leafOffset !== representativeJsonStringifyExpectedLeafOffset ||
        encoded.charCodeAt(0) !== 91 || encoded.charCodeAt(encoded.length - 1) !== 93)
      throw new Error("JSON.stringify shallow witness drift");
    total = total + encoded.length + leafOffset +
      encoded.charCodeAt(0) + encoded.charCodeAt(encoded.length - 1) + lane;
  }
  return total;
}

// String inputs are constructed and their exact probes are frozen before the
// ten runner warmups. The scored job includes one real JSON.stringify plus
// fixed-size output validation, without hashing or rescanning the full result.
var representativeJsonStringifyStringInput = "";
var representativeJsonStringifyStringKind = "";
var representativeJsonStringifyStringExpectedLength = 0;
var representativeJsonStringifyStringProbe0 = "";
var representativeJsonStringifyStringProbe1 = "";
var representativeJsonStringifyStringProbe2 = "";
var representativeJsonStringifyStringProbe0Offset = 0;
var representativeJsonStringifyStringProbe1Offset = 0;
var representativeJsonStringifyStringProbe2Offset = 0;

function representativeJsonStringifyPattern(pattern, repetitions) {
  var result = "";
  var chunk = pattern;
  var count = repetitions;
  while (count > 0) {
    if ((count & 1) !== 0) result = result + chunk;
    count = Math.floor(count / 2);
    if (count !== 0) chunk = chunk + chunk;
  }
  return result;
}

function selectRepresentativeJsonStringifyString(kind, extent) {
  var input;
  if (kind === "plain") {
    input = representativeJsonStringifyPattern("a", extent);
  } else if (kind === "unicode") {
    // Valid 2-, 3-, and 4-byte UTF-8 sequences separated by ASCII.
    input = representativeJsonStringifyPattern("Aé水😀", extent);
  } else if (kind === "sparse") {
    var ordinary = representativeJsonStringifyPattern("p", extent);
    var mixed = "\"\\\n\t\r\b\f\u0000\u0007\u000b\u001f";
    var chunks = [];
    for (var index = 0; index < 16; index = index + 1)
      chunks.push(ordinary + mixed);
    input = chunks.join("");
  } else if (kind === "surrogate") {
    // Separators keep both code units lone so WTF-8 must emit two lowercase
    // JSON \u escapes rather than combine them into a scalar value.
    input = representativeJsonStringifyPattern("\ud800x\udc00y", extent);
  } else {
    input = "short-safe-ASCII-19";
  }

  var expected = JSON.stringify(input);
  var probeWidth = 12;
  representativeJsonStringifyStringInput = input;
  representativeJsonStringifyStringKind = kind;
  representativeJsonStringifyStringExpectedLength = expected.length;
  representativeJsonStringifyStringProbe0Offset = 0;
  representativeJsonStringifyStringProbe1Offset = Math.floor(expected.length / 2);
  representativeJsonStringifyStringProbe2Offset = Math.max(0, expected.length - probeWidth);
  representativeJsonStringifyStringProbe0 = expected.slice(0, probeWidth);
  representativeJsonStringifyStringProbe1 = expected.slice(
    representativeJsonStringifyStringProbe1Offset,
    representativeJsonStringifyStringProbe1Offset + probeWidth
  );
  representativeJsonStringifyStringProbe2 = expected.slice(
    representativeJsonStringifyStringProbe2Offset,
    representativeJsonStringifyStringProbe2Offset + probeWidth
  );
  return representativeJsonStringifyString;
}

function representativeJsonStringifyString(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var encoded = JSON.stringify(representativeJsonStringifyStringInput);
    if (encoded.length !== representativeJsonStringifyStringExpectedLength ||
        encoded.slice(representativeJsonStringifyStringProbe0Offset,
          representativeJsonStringifyStringProbe0Offset + representativeJsonStringifyStringProbe0.length) !== representativeJsonStringifyStringProbe0 ||
        encoded.slice(representativeJsonStringifyStringProbe1Offset,
          representativeJsonStringifyStringProbe1Offset + representativeJsonStringifyStringProbe1.length) !== representativeJsonStringifyStringProbe1 ||
        encoded.slice(representativeJsonStringifyStringProbe2Offset,
          representativeJsonStringifyStringProbe2Offset + representativeJsonStringifyStringProbe2.length) !== representativeJsonStringifyStringProbe2)
      throw new Error("JSON.stringify string witness drift: " + representativeJsonStringifyStringKind);
    total = total + encoded.length +
      representativeJsonStringifyStringProbe0Offset +
      representativeJsonStringifyStringProbe1Offset +
      representativeJsonStringifyStringProbe2Offset +
      encoded.charCodeAt(representativeJsonStringifyStringProbe0Offset) +
      encoded.charCodeAt(representativeJsonStringifyStringProbe1Offset) +
      encoded.charCodeAt(representativeJsonStringifyStringProbe2Offset) + lane;
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

// Exercise every non-locale Date string conversion (including the Date fast
// path through toJSON) at deterministic
// 1K/2K/4K widths. The noon-UTC inputs keep the date prefix equal on this
// reference host while the checksum deliberately ignores local-time digits and
// zone names, whose exact spelling is outside the cross-engine contract. Every
// complete result is still constructed and consumed. The getter control keeps
// the identical Date mutation and component reads without formatting a string.
function selectRepresentativeDateString(width, control) {
  return function (jobs, lane) {
    var total = 0;
    for (var job = 0; job < jobs; job = job + 1) {
      var date = new Date(0);
      for (var index = 0; index < width; index = index + 1) {
        var day = (index + job * 17 + lane * 29) % 7305;
        date.setTime(946728000000 + day * 86400000);
        if (control) {
          total = total + date.getUTCFullYear() + date.getUTCMonth() +
            date.getUTCDate() + date.getUTCDay() + date.getUTCHours();
          continue;
        }
        var dateText = date.toDateString();
        var timeText = date.toTimeString();
        var fullText = date.toString();
        var utcText = date.toUTCString();
        var isoText = date.toISOString();
        var jsonText = date.toJSON();
        for (var dateIndex = 0; dateIndex < 15; dateIndex = dateIndex + 1) {
          total = total + dateText.charCodeAt(dateIndex);
          total = total + fullText.charCodeAt(dateIndex);
        }
        total = total + timeText.charCodeAt(2) + timeText.charCodeAt(5) +
          timeText.charCodeAt(8) + timeText.charCodeAt(9) +
          timeText.charCodeAt(10) + timeText.charCodeAt(11);
        for (var utcIndex = 0; utcIndex < utcText.length; utcIndex = utcIndex + 1)
          total = total + utcText.charCodeAt(utcIndex);
        for (var isoIndex = 0; isoIndex < isoText.length; isoIndex = isoIndex + 1) {
          total = total + isoText.charCodeAt(isoIndex);
          total = total + jsonText.charCodeAt(isoIndex);
        }
      }
    }
    return total;
  };
}

// CanonicalizeLocaleList rows keep fixture construction outside the timed
// boundary, then force every indexed HasProperty/Get/canonicalization step on
// each invocation. Private-use subtags provide thousands of distinct, valid
// language tags without depending on host locale availability. The duplicate
// row preserves the same input width but collapses it to 32 first occurrences;
// the small row guards the ordinary-list path against indexing overhead.
var representativeLocaleListSelected = null;
function selectRepresentativeLocaleList(width, duplicateHeavy) {
  var locales = [];
  for (var index = 0; index < width; index = index + 1) {
    var identity = duplicateHeavy ? index % 32 : index;
    var privateUse = identity.toString(36);
    locales.push((index & 1 ? "EN-x-" : "en-X-") + privateUse);
  }
  representativeLocaleListSelected = locales;
  return representativeLocaleList;
}

function representativeLocaleList(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var locales = Intl.getCanonicalLocales(representativeLocaleListSelected);
    var first = locales[0];
    var middle = locales[locales.length >> 1];
    var last = locales[locales.length - 1];
    total = total + locales.length + first.length + middle.length + last.length +
      first.charCodeAt(first.length - 1) +
      middle.charCodeAt(middle.length - 1) +
      last.charCodeAt(last.length - 1) + lane;
  }
  return total;
}

// Generic Array iteration rows keep fixture construction outside the timed
// boundary. Plain array-likes force the exact HasProperty/Get path for every
// present index; the sparse Proxy records both traps while exposing only even
// indices. The dense control performs identical callback work without generic
// numeric-property keys.
var representativeArrayTraversalSelected = null;
var representativeArrayTraversalProxy = false;
var representativeArrayTraversalHasTraps = 0;
var representativeArrayTraversalGetTraps = 0;
function selectRepresentativeArrayTraversal(width, kind) {
  var target = kind === "dense" ? [] : { length: width };
  for (var index = 0; index < width; index = index + 1) {
    if (kind !== "proxy" || (index & 1) === 0)
      target[index] = index * 3 + 1;
  }
  representativeArrayTraversalProxy = kind === "proxy";
  representativeArrayTraversalSelected = representativeArrayTraversalProxy
    ? new Proxy(target, {
        has: function (object, key) {
          representativeArrayTraversalHasTraps = representativeArrayTraversalHasTraps + 1;
          return Reflect.has(object, key);
        },
        get: function (object, key) {
          if (key !== "length")
            representativeArrayTraversalGetTraps = representativeArrayTraversalGetTraps + 1;
          return Reflect.get(object, key);
        }
      })
    : target;
  return representativeArrayTraversal;
}

function representativeArrayTraversal(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    representativeArrayTraversalHasTraps = 0;
    representativeArrayTraversalGetTraps = 0;
    var callbacks = 0;
    var callbackTotal = 0;
    Array.prototype.forEach.call(representativeArrayTraversalSelected, function (value, index, source) {
      callbackTotal = callbackTotal + value + index + lane;
      callbacks = callbacks + (source === representativeArrayTraversalSelected ? 1 : 1000000);
    });
    total = total + callbackTotal + callbacks;
    if (representativeArrayTraversalProxy)
      total = total + representativeArrayTraversalHasTraps * 5 + representativeArrayTraversalGetTraps * 7;
  }
  return total;
}

// Shared transition publication uses a fresh base shape for every invocation.
// The main realm publishes one unique base-key transition per lane before
// workers start. Every lane then reaches its prepared base shape and publishes
// disjoint fanout edges beneath it. Unique property-name construction is also
// fixture work: prepare freezes one key array per lane so the timed boundary
// measures publication rather than integer/string formatting. The contended
// control deliberately maps all lanes to one base instead. The checksum covers
// every published object/value but is independent of the invocation epoch, so
// timed samples do equal work.
var representativeShapeTransitionEpoch = 0;
var representativeShapeTransitionBaseKeys = [];
var representativeShapeTransitionKeys = [];
var representativeShapeTransitionVariant = 0;
var representativeShapeTransitionContended = false;
function representativeShapeTransitionPrepare(jobs, lanes) {
  representativeShapeTransitionEpoch = representativeShapeTransitionEpoch + 1;
  representativeShapeTransitionBaseKeys = [];
  representativeShapeTransitionKeys = [];
  for (var lane = 0; lane < lanes; lane = lane + 1) {
    var owner = representativeShapeTransitionContended ? 0 : lane;
    var key = (representativeShapeTransitionVariant ? "shape-variant-base-" : "shape-base-") +
      representativeShapeTransitionEpoch + "-owner-" + owner;
    representativeShapeTransitionBaseKeys.push(key);
    var base = {};
    base[key] = 0;
    var keys = [];
    for (var job = 0; job < jobs; job = job + 1) {
      keys.push(representativeShapeTransitionVariant
        ? "published-variant-" + job + "-lane-" + lane
        : "published-lane-" + lane + "-job-" + job);
    }
    representativeShapeTransitionKeys.push(keys);
  }
}

function selectRepresentativeShapeTransitionFanout(variant, contended) {
  representativeShapeTransitionVariant = variant;
  representativeShapeTransitionContended = contended;
  globalThis.__benchmarkPrepare = representativeShapeTransitionPrepare;
  return function (jobs, lane) {
    var total = 0;
    var baseKey = representativeShapeTransitionBaseKeys[
      representativeShapeTransitionContended ? 0 : lane
    ];
    var keys = representativeShapeTransitionKeys[lane];
    var object = {};
    object[baseKey] = 0;
    for (var job = 0; job < jobs; job = job + 1) {
      var key = keys[job];
      var value = (lane + 1) * (job + 1);
      object[key] = value;
      var observed = object[key];
      var deleted = delete object[key];
      total = total + observed + (deleted ? 1 : 1000000);
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

var representativeIntlDefaultFormatter = new Intl.NumberFormat("en-US");
var representativeIntlFractionFormatter = new Intl.NumberFormat("en-US", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
});
var representativeIntlLocaleFormatter = new Intl.NumberFormat("de-DE", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
});
var representativeIntlUncommonFormatter = new Intl.NumberFormat("hi-IN-u-nu-deva", {
  style: "currency",
  currency: "INR",
  currencyDisplay: "name",
  notation: "compact",
  compactDisplay: "long",
  minimumSignificantDigits: 3,
  maximumSignificantDigits: 5,
  useGrouping: "min2",
  signDisplay: "exceptZero"
});

function representativeIntlNumberFormatSteady(jobs, lane, kind) {
  var formatter = kind === "default" ? representativeIntlDefaultFormatter :
    (kind === "fraction" ? representativeIntlFractionFormatter :
      (kind === "locale" ? representativeIntlLocaleFormatter : representativeIntlUncommonFormatter));
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 256; i = i + 1) {
      var output = formatter.format((job + 1) * 1000 + i + lane / 10);
      total = total + output.length + output.charCodeAt(0) + output.charCodeAt(output.length - 1);
    }
  }
  return total;
}

function representativeIntlNumberFormatConstruct(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 32; i = i + 1) {
      var formatter;
      if (kind === "default") {
        formatter = new Intl.NumberFormat("en-US");
      } else if (kind === "fraction") {
        formatter = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
      } else if (kind === "locale") {
        formatter = new Intl.NumberFormat("de-DE", { maximumFractionDigits: 2, minimumFractionDigits: 2 });
      } else {
        formatter = new Intl.NumberFormat("hi-IN-u-nu-deva", {
          signDisplay: "exceptZero",
          useGrouping: "min2",
          maximumSignificantDigits: 5,
          minimumSignificantDigits: 3,
          compactDisplay: "long",
          notation: "compact",
          currencyDisplay: "name",
          currency: "INR",
          style: "currency"
        });
      }
      var options = formatter.resolvedOptions();
      var minFraction = options.minimumFractionDigits === undefined ? 0 : options.minimumFractionDigits;
      var maxFraction = options.maximumFractionDigits === undefined ? 0 : options.maximumFractionDigits;
      var minSignificant = options.minimumSignificantDigits === undefined ? 0 : options.minimumSignificantDigits;
      var maxSignificant = options.maximumSignificantDigits === undefined ? 0 : options.maximumSignificantDigits;
      total = total + options.locale.length + options.style.length + options.minimumIntegerDigits +
        minFraction + maxFraction + minSignificant + maxSignificant + lane + (job & 3);
    }
  }
  return total;
}

var representativeIntlStructureFormatters = [
  new Intl.NumberFormat("en-US"),
  new Intl.NumberFormat("en-US", { useGrouping: false, minimumFractionDigits: 4, signDisplay: "always" }),
  new Intl.NumberFormat("hi-IN-u-nu-deva", { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", currencySign: "accounting" }),
  new Intl.NumberFormat("de-DE", { style: "unit", unit: "kilometer-per-hour", unitDisplay: "long" }),
  new Intl.NumberFormat("en-US", { notation: "scientific", maximumSignificantDigits: 5 }),
  new Intl.NumberFormat("en-US", { notation: "compact", compactDisplay: "long" }),
  new Intl.NumberFormat("de-DE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
];
var representativeIntlStructureValues = [
  123456.75, -0, -1234.5, NaN, Infinity, 12345678901234567890n, 0.00425, 987654321
];

function representativeIntlNumberFormatConsumer(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var index = (job + i + lane) & 7;
      var formatter = representativeIntlStructureFormatters[index];
      var value = representativeIntlStructureValues[index];
      if (kind === "text") {
        var output = formatter.format(value);
        total = total + output.length + output.charCodeAt(0) + output.charCodeAt(output.length - 1);
      } else if (kind === "parts") {
        var parts = formatter.formatToParts(value);
        total = total + parts.length;
        for (var part = 0; part < parts.length; part = part + 1)
          total = total + parts[part].type.length + parts[part].value.length + parts[part].value.charCodeAt(0);
      } else if (kind === "range") {
        var range = formatter.formatRange((job + 1) * 1000 + i, (job + 1) * 1000 + i + 500.25);
        total = total + range.length + range.charCodeAt(0) + range.charCodeAt(range.length - 1);
      } else {
        var rangeParts = formatter.formatRangeToParts((job + 1) * 1000 + i, (job + 1) * 1000 + i + 500.25);
        total = total + rangeParts.length;
        for (var rangePart = 0; rangePart < rangeParts.length; rangePart = rangePart + 1)
          total = total + rangeParts[rangePart].type.length + rangeParts[rangePart].value.length +
            rangeParts[rangePart].source.length + rangeParts[rangePart].value.charCodeAt(0);
      }
    }
  }
  return total;
}

var representativeIntlRoundingFormatters = [
  new Intl.NumberFormat("en-US"),
  new Intl.NumberFormat("en-US", { useGrouping: false, minimumFractionDigits: 4, maximumFractionDigits: 4, signDisplay: "always" }),
  new Intl.NumberFormat("en-US", { minimumSignificantDigits: 3, maximumSignificantDigits: 5 }),
  new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2, roundingIncrement: 5, roundingMode: "halfEven" }),
  new Intl.NumberFormat("en-US", { notation: "scientific", maximumSignificantDigits: 6 }),
  new Intl.NumberFormat("en-US", { notation: "engineering", minimumSignificantDigits: 4, maximumSignificantDigits: 6 }),
  new Intl.NumberFormat("en-US", { notation: "compact", compactDisplay: "long" }),
  new Intl.NumberFormat("en-US", { useGrouping: false, maximumFractionDigits: 0 }),
  new Intl.NumberFormat("en-US", { useGrouping: false, minimumFractionDigits: 2, maximumFractionDigits: 4 }),
  new Intl.NumberFormat("hi-IN-u-nu-deva", { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", currencySign: "accounting", maximumFractionDigits: 2 }),
  new Intl.NumberFormat("de-DE", { maximumFractionDigits: 3 }),
  new Intl.NumberFormat("en-US", { useGrouping: false }),
  new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 4, minimumSignificantDigits: 3, maximumSignificantDigits: 5, roundingPriority: "morePrecision" }),
  new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, trailingZeroDisplay: "stripIfInteger" }),
  new Intl.NumberFormat("en-US", { useGrouping: false, minimumIntegerDigits: 21 })
];
var representativeIntlRoundingValues = [
  123456.75,
  -0,
  98765.4321,
  1.025,
  123456789.125,
  0.000123456,
  1234567,
  1.7976931348623157e308,
  "000000000000123.4500",
  -1234.5,
  -42.125,
  NaN,
  -Infinity,
  0.004321,
  42,
  7
];

function representativeIntlNumberFormatRounding(jobs, lane, partsMode) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var index = (job + i + lane) & 15;
      var formatter = representativeIntlRoundingFormatters[index];
      var value = representativeIntlRoundingValues[index];
      if (partsMode) {
        var parts = formatter.formatToParts(value);
        total = total + parts.length;
        for (var part = 0; part < parts.length; part = part + 1)
          total = total + parts[part].type.length + parts[part].value.length + parts[part].value.charCodeAt(0);
      } else {
        var output = formatter.format(value);
        total = total + output.length + output.charCodeAt(0) + output.charCodeAt(output.length - 1);
      }
    }
  }
  return total;
}

var representativeIntlCompactFormatters = [
  new Intl.NumberFormat("en-US", { notation: "compact" }),
  new Intl.NumberFormat("en-US", { notation: "compact", compactDisplay: "long", maximumSignificantDigits: 4 }),
  new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 }),
  new Intl.NumberFormat("en-US", { notation: "compact", minimumFractionDigits: 2, maximumFractionDigits: 2 }),
  new Intl.NumberFormat("en-US", { notation: "compact", minimumSignificantDigits: 4, maximumSignificantDigits: 4 }),
  new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2, maximumSignificantDigits: 4, roundingPriority: "morePrecision" }),
  new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2, maximumSignificantDigits: 4, roundingPriority: "lessPrecision" }),
  new Intl.NumberFormat("en-US", { notation: "compact" }),
  new Intl.NumberFormat("en-US", { notation: "compact" }),
  new Intl.NumberFormat("en-US-u-nu-deva", { notation: "compact", maximumSignificantDigits: 3 }),
  new Intl.NumberFormat("de-DE", { notation: "compact", compactDisplay: "long", maximumSignificantDigits: 3 }),
  new Intl.NumberFormat("ja-JP", { notation: "compact", maximumSignificantDigits: 4 }),
  new Intl.NumberFormat("en-US", { notation: "compact", signDisplay: "always" }),
  new Intl.NumberFormat("en-US", { notation: "compact", maximumSignificantDigits: 3, roundingMode: "floor" }),
  new Intl.NumberFormat("en-US", { notation: "compact", maximumSignificantDigits: 3, roundingMode: "ceil" }),
  new Intl.NumberFormat("en-US", { notation: "compact", minimumFractionDigits: 2, maximumFractionDigits: 2, trailingZeroDisplay: "stripIfInteger" })
];
var representativeIntlCompactValues = [
  1234567,
  1234567,
  1234567,
  1234567,
  1234567,
  1234567,
  1234567,
  999500,
  999499,
  1234567,
  1234567,
  12345678,
  -0,
  1999,
  1001,
  1000
];

function representativeIntlNumberFormatCompact(jobs, lane, partsMode) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var index = (job + i + lane) & 15;
      var formatter = representativeIntlCompactFormatters[index];
      var value = representativeIntlCompactValues[index];
      if (partsMode) {
        var parts = formatter.formatToParts(value);
        total = total + parts.length;
        for (var part = 0; part < parts.length; part = part + 1)
          total = total + parts[part].type.length + parts[part].value.length + parts[part].value.charCodeAt(0);
      } else {
        var output = formatter.format(value);
        total = total + output.length + output.charCodeAt(0) + output.charCodeAt(output.length - 1);
      }
    }
  }
  return total;
}

var representativeIntlBigIntFormatters = [
  new Intl.NumberFormat("en-US"),
  new Intl.NumberFormat("en-US", { useGrouping: false, minimumFractionDigits: 4, signDisplay: "always" }),
  new Intl.NumberFormat("hi-IN-u-nu-deva", { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", currencySign: "accounting" }),
  new Intl.NumberFormat("de-DE", { style: "currency", currency: "EUR", currencyDisplay: "name" }),
  new Intl.NumberFormat("de-DE", { style: "percent", minimumFractionDigits: 2 }),
  new Intl.NumberFormat("en-US", { style: "unit", unit: "meter-per-second", unitDisplay: "long" }),
  new Intl.NumberFormat("en-US", { notation: "compact", compactDisplay: "long" }),
  new Intl.NumberFormat("en-US", { notation: "scientific", maximumFractionDigits: 3 }),
  new Intl.NumberFormat("en-US", { notation: "engineering", maximumSignificantDigits: 5 }),
  new Intl.NumberFormat("en-US", { maximumSignificantDigits: 5 }),
  new Intl.NumberFormat("en-US", { maximumSignificantDigits: 3 }),
  new Intl.NumberFormat("en-US", { signDisplay: "always" }),
  new Intl.NumberFormat("en-US", { signDisplay: "exceptZero" }),
  new Intl.NumberFormat("en-US", { minimumIntegerDigits: 21, useGrouping: false }),
  new Intl.NumberFormat("en-US", { maximumSignificantDigits: 5, roundingMode: "floor" })
];
var representativeIntlBigIntValues = [
  0n,
  12345678901234567890n,
  1234567890123456789012345678901234567890n,
  -12345678901234567890n,
  2n,
  12345678901234567890n,
  2n,
  1234567890123456789012345678901234567890n,
  1234567890123456789012345678901234567890n,
  1234567890123456789012345678901234567890n,
  1234567890123456789012345678901234567890n,
  12345678901234567890n,
  42n,
  0n,
  7n,
  -19999n
];

function representativeIntlNumberFormatBigInt(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var index = (job + i + lane) & 15;
      var formatter = representativeIntlBigIntFormatters[index];
      var value = representativeIntlBigIntValues[index];
      if (kind === "text") {
        var output = formatter.format(value);
        total = total + output.length + output.charCodeAt(0) + output.charCodeAt(output.length - 1);
      } else if (kind === "parts") {
        var parts = formatter.formatToParts(value);
        total = total + parts.length;
        for (var part = 0; part < parts.length; part = part + 1)
          total = total + parts[part].type.length + parts[part].value.length + parts[part].value.charCodeAt(0);
      } else {
        var end = value + BigInt(109 + ((job + i) & 31));
        if (kind === "range") {
          var range = formatter.formatRange(value, end);
          total = total + range.length + range.charCodeAt(0) + range.charCodeAt(range.length - 1);
        } else {
          var rangeParts = formatter.formatRangeToParts(value, end);
          total = total + rangeParts.length;
          for (var rangePart = 0; rangePart < rangeParts.length; rangePart = rangePart + 1)
            total = total + rangeParts[rangePart].type.length + rangeParts[rangePart].value.length +
              rangeParts[rangePart].source.length + rangeParts[rangePart].value.charCodeAt(0);
        }
      }
    }
  }
  return total;
}

var representativeIntlCompactCldrFormatters = [
  new Intl.NumberFormat("en-US", { notation: "compact" }),
  new Intl.NumberFormat("en-US", { notation: "compact", compactDisplay: "long", maximumSignificantDigits: 4 }),
  new Intl.NumberFormat("de-DE", { notation: "compact" }),
  new Intl.NumberFormat("de-DE", { notation: "compact", compactDisplay: "long" }),
  new Intl.NumberFormat("fr-FR", { notation: "compact", compactDisplay: "long" }),
  new Intl.NumberFormat("hi-IN-u-nu-deva", { notation: "compact", compactDisplay: "long" }),
  new Intl.NumberFormat("hi-IN-u-nu-deva", { notation: "compact", maximumSignificantDigits: 3 }),
  new Intl.NumberFormat("ja-JP", { notation: "compact", maximumSignificantDigits: 4 }),
  new Intl.NumberFormat("zh-CN", { notation: "compact", maximumSignificantDigits: 4 }),
  new Intl.NumberFormat("ko-KR", { notation: "compact", maximumSignificantDigits: 4 }),
  new Intl.NumberFormat("he-IL", { notation: "compact", compactDisplay: "long" }),
  new Intl.NumberFormat("ru-RU", { notation: "compact", compactDisplay: "long", maximumSignificantDigits: 3 }),
  new Intl.NumberFormat("ar", { notation: "compact", compactDisplay: "long", maximumSignificantDigits: 3 }),
  new Intl.NumberFormat("fr-FR", { notation: "compact", compactDisplay: "long" }),
  new Intl.NumberFormat("de-DE", { notation: "compact", compactDisplay: "long" }),
  new Intl.NumberFormat("en-US", { notation: "compact" })
];
var representativeIntlCompactCldrValues = [
  1234567, 1234567, 1234567, 1000000, 1000, 1234567, 1234567, 12345678,
  12345678, 12345678, 1200, 22000, 3000, 2000000, 2000000, 999500
];
var representativeIntlCompactCldrEnds = [
  2345678, 2345678, 2345678, 2000000, 2000, 2345678, 2345678, 23456789,
  23456789, 23456789, 2200, 25000, 5000, 3000000, 3000000, 1000500
];

function representativeIntlNumberFormatCompactCldr(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var index = (job + i + lane) & 15;
      var formatter = representativeIntlCompactCldrFormatters[index];
      if (kind === "text") {
        var output = formatter.format(representativeIntlCompactCldrValues[index]);
        total = total + output.length + output.charCodeAt(0) + output.charCodeAt(output.length - 1);
      } else if (kind === "parts") {
        var parts = formatter.formatToParts(representativeIntlCompactCldrValues[index]);
        total = total + parts.length;
        for (var part = 0; part < parts.length; part = part + 1)
          total = total + parts[part].type.length + parts[part].value.length + parts[part].value.charCodeAt(0);
      } else if (kind === "range") {
        var range = formatter.formatRange(representativeIntlCompactCldrValues[index], representativeIntlCompactCldrEnds[index]);
        total = total + range.length + range.charCodeAt(0) + range.charCodeAt(range.length - 1);
      } else {
        var rangeParts = formatter.formatRangeToParts(representativeIntlCompactCldrValues[index], representativeIntlCompactCldrEnds[index]);
        total = total + rangeParts.length;
        for (var rangePart = 0; rangePart < rangeParts.length; rangePart = rangePart + 1)
          total = total + rangeParts[rangePart].type.length + rangeParts[rangePart].value.length +
            rangeParts[rangePart].source.length + rangeParts[rangePart].value.charCodeAt(0);
      }
    }
  }
  return total;
}

var representativeIntlCurrencyNameCldrFormatters = [
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", currencyDisplay: "name" }),
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", currencyDisplay: "name", trailingZeroDisplay: "stripIfInteger" }),
  new Intl.NumberFormat("de-DE", { style: "currency", currency: "EUR", currencyDisplay: "name" }),
  new Intl.NumberFormat("fr-FR", { style: "currency", currency: "EUR", currencyDisplay: "name" }),
  new Intl.NumberFormat("es-ES", { style: "currency", currency: "USD", currencyDisplay: "name" }),
  new Intl.NumberFormat("it-IT", { style: "currency", currency: "EUR", currencyDisplay: "name" }),
  new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL", currencyDisplay: "name" }),
  new Intl.NumberFormat("ru-RU", { style: "currency", currency: "RUB", currencyDisplay: "name", trailingZeroDisplay: "stripIfInteger" }),
  new Intl.NumberFormat("pl-PL", { style: "currency", currency: "PLN", currencyDisplay: "name", trailingZeroDisplay: "stripIfInteger" }),
  new Intl.NumberFormat("ar-EG-u-nu-arab", { style: "currency", currency: "EGP", currencyDisplay: "name", trailingZeroDisplay: "stripIfInteger" }),
  new Intl.NumberFormat("hi-IN-u-nu-deva", { style: "currency", currency: "INR", currencyDisplay: "name" }),
  new Intl.NumberFormat("ja-JP", { style: "currency", currency: "JPY", currencyDisplay: "name" }),
  new Intl.NumberFormat("zh-CN", { style: "currency", currency: "CNY", currencyDisplay: "name" }),
  new Intl.NumberFormat("ko-KR", { style: "currency", currency: "KRW", currencyDisplay: "name" }),
  new Intl.NumberFormat("he-IL", { style: "currency", currency: "ILS", currencyDisplay: "name" }),
  new Intl.NumberFormat("cy-GB", { style: "currency", currency: "GBP", currencyDisplay: "name", trailingZeroDisplay: "stripIfInteger" })
];
var representativeIntlCurrencyNameCldrValues = [
  1, 1n, 2n, 2, 2n, 2, 2n, 21n, 22n, 3n, 2n, 2n, 2, 2n, 2, 3n
];
var representativeIntlCurrencyNameCldrEnds = [
  2, 2n, 3n, 3, 3n, 3, 3n, 25n, 25n, 11n, 3n, 3n, 3, 3n, 3, 6n
];

function representativeIntlNumberFormatCurrencyNameCldr(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var index = (job + i + lane) & 15;
      var formatter = representativeIntlCurrencyNameCldrFormatters[index];
      if (kind === "text") {
        var output = formatter.format(representativeIntlCurrencyNameCldrValues[index]);
        total = total + output.length + output.charCodeAt(0) + output.charCodeAt(output.length - 1);
      } else if (kind === "parts") {
        var parts = formatter.formatToParts(representativeIntlCurrencyNameCldrValues[index]);
        total = total + parts.length;
        for (var part = 0; part < parts.length; part = part + 1)
          total = total + parts[part].type.length + parts[part].value.length + parts[part].value.charCodeAt(0);
      } else if (kind === "range") {
        var range = formatter.formatRange(representativeIntlCurrencyNameCldrValues[index], representativeIntlCurrencyNameCldrEnds[index]);
        total = total + range.length + range.charCodeAt(0) + range.charCodeAt(range.length - 1);
      } else {
        var rangeParts = formatter.formatRangeToParts(representativeIntlCurrencyNameCldrValues[index], representativeIntlCurrencyNameCldrEnds[index]);
        total = total + rangeParts.length;
        for (var rangePart = 0; rangePart < rangeParts.length; rangePart = rangePart + 1)
          total = total + rangeParts[rangePart].type.length + rangeParts[rangePart].value.length +
            rangeParts[rangePart].source.length + rangeParts[rangePart].value.charCodeAt(0);
      }
    }
  }
  return total;
}

var representativeIntlNumberingSystemCldrFormatters = [
  new Intl.NumberFormat("ar"),
  new Intl.NumberFormat("ar-EG"),
  new Intl.NumberFormat("ar-TN"),
  new Intl.NumberFormat("fa-IR"),
  new Intl.NumberFormat("hi-IN"),
  new Intl.NumberFormat("th-TH"),
  new Intl.NumberFormat("en-US-u-nu-arab"),
  new Intl.NumberFormat("en-US-u-nu-deva"),
  new Intl.NumberFormat("ar-EG-u-nu-latn"),
  new Intl.NumberFormat("fa-IR-u-nu-latn"),
  new Intl.NumberFormat("hi-IN-u-nu-deva"),
  new Intl.NumberFormat("th-TH-u-nu-thai"),
  new Intl.NumberFormat("ar-EG-u-nu-arab", { numberingSystem: "latn" }),
  new Intl.NumberFormat("en-US-u-nu-latn", { numberingSystem: "arab" }),
  new Intl.NumberFormat("fa-IR-u-nu-arabext", { numberingSystem: "latn" }),
  new Intl.NumberFormat("hi-IN-u-nu-latn", { numberingSystem: "deva" })
];
var representativeIntlNumberingSystemCldrValues = [
  1234.5, 1234.5, 1234.5, 1234.5, 1234.5, 1234.5, 1234.5, 1234.5,
  12345678901234567890n, 12345678901234567890n, 12345678901234567890n, 12345678901234567890n,
  -1234.5, -1234.5, -1234.5, -1234.5
];
var representativeIntlNumberingSystemCldrEnds = [
  2345.6, 2345.6, 2345.6, 2345.6, 2345.6, 2345.6, 2345.6, 2345.6,
  22345678901234567890n, 22345678901234567890n, 22345678901234567890n, 22345678901234567890n,
  1234.5, 1234.5, 1234.5, 1234.5
];

function representativeIntlNumberFormatNumberingSystemCldr(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var index = (job + i + lane) & 15;
      var formatter = representativeIntlNumberingSystemCldrFormatters[index];
      if (kind === "text") {
        var output = formatter.format(representativeIntlNumberingSystemCldrValues[index]);
        total = total + output.length + output.charCodeAt(0) + output.charCodeAt(output.length - 1);
      } else if (kind === "parts") {
        var parts = formatter.formatToParts(representativeIntlNumberingSystemCldrValues[index]);
        total = total + parts.length;
        for (var part = 0; part < parts.length; part = part + 1)
          total = total + parts[part].type.length + parts[part].value.length + parts[part].value.charCodeAt(0);
      } else if (kind === "range") {
        var range = formatter.formatRange(representativeIntlNumberingSystemCldrValues[index], representativeIntlNumberingSystemCldrEnds[index]);
        total = total + range.length + range.charCodeAt(0) + range.charCodeAt(range.length - 1);
      } else {
        var options = formatter.resolvedOptions();
        total = total + options.locale.length + options.numberingSystem.length +
          options.numberingSystem.charCodeAt(0) + options.numberingSystem.charCodeAt(options.numberingSystem.length - 1);
      }
    }
  }
  return total;
}

// Structural Intl services keep formatter and input construction outside the
// timed boundary. Each row consumes every type/value/unit byte so metadata
// ownership changes remain attributable without weakening the output oracle.
var representativeIntlListFormatter = new Intl.ListFormat("en-US", {
  style: "long", type: "conjunction"
});
var representativeIntlListInputs = [
  ["alpha", "beta", "gamma"], ["red", "green", "blue", "gold"],
  ["north", "south"], ["one", "two", "three", "four", "five"],
  ["small", "medium", "large"], ["spring", "summer", "autumn", "winter"],
  ["left", "center", "right"], ["read", "write", "execute"]
];
var representativeIntlRelativeFormatter = new Intl.RelativeTimeFormat("en-US", {
  numeric: "always", style: "long"
});
var representativeIntlRelativeValues = [-12, -3, -1, 0, 1, 3, 12, 1250];
var representativeIntlRelativeUnits = [
  "day", "hour", "minute", "second", "week", "month", "quarter", "year"
];
var representativeIntlDurationFormatter = new Intl.DurationFormat("en-US", {
  style: "long"
});
var representativeIntlDurationInputs = [
  { hours: 1, minutes: 2, seconds: 3 },
  { days: 2, hours: 4, minutes: 8 },
  { years: 1, months: 6, days: 12 },
  { minutes: 15, seconds: 30, milliseconds: 250 },
  { weeks: 3, days: 2, hours: 1 },
  { seconds: 45, milliseconds: 125, microseconds: 500 },
  { hours: 12, minutes: 34, seconds: 56 },
  { months: 9, weeks: 2, days: 5 }
];

function representativeIntlStructuralChecksum(parts) {
  var total = parts.length;
  for (var part = 0; part < parts.length; part = part + 1) {
    total = (total + representativeIntlDateTimeChecksum(parts[part].type) +
      representativeIntlDateTimeChecksum(parts[part].value)) % 1000000007;
    if (parts[part].unit !== undefined)
      total = (total + representativeIntlDateTimeChecksum(parts[part].unit)) % 1000000007;
  }
  return total;
}

function representativeIntlStructuralService(jobs, lane, service) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var index = (job + i + lane) & 7;
      var parts;
      if (service === "list") {
        parts = representativeIntlListFormatter.formatToParts(representativeIntlListInputs[index]);
      } else if (service === "relative") {
        parts = representativeIntlRelativeFormatter.formatToParts(
          representativeIntlRelativeValues[index], representativeIntlRelativeUnits[index]
        );
      } else {
        parts = representativeIntlDurationFormatter.formatToParts(representativeIntlDurationInputs[index]);
      }
      total = (total + representativeIntlStructuralChecksum(parts)) % 1000000007;
    }
  }
  return total;
}

// DurationFormat resolved-state consumers keep construction outside the timed
// boundary and consume every reflected field from each fresh result. The
// matrix covers the four base styles, the unit-style cascade, display choices,
// numbering-system resolution, and optional fractionalDigits.
var representativeIntlDurationResolvedFormatters = [
  new Intl.DurationFormat("en-US"),
  new Intl.DurationFormat("en-US", { style: "long" }),
  new Intl.DurationFormat("en-US", { style: "narrow" }),
  new Intl.DurationFormat("en-US", { style: "digital" }),
  new Intl.DurationFormat("en-US", {
    style: "long", years: "short", months: "narrow", weeks: "long", days: "short"
  }),
  new Intl.DurationFormat("en-US", {
    style: "digital", hours: "2-digit", minutes: "numeric", seconds: "2-digit", fractionalDigits: 3
  }),
  new Intl.DurationFormat("en-US", {
    style: "short", seconds: "numeric", milliseconds: "numeric",
    microseconds: "numeric", nanoseconds: "numeric", fractionalDigits: 6
  }),
  new Intl.DurationFormat("en-US", {
    numberingSystem: "latn", style: "long", daysDisplay: "always", hoursDisplay: "auto"
  })
];
var representativeIntlDurationResolvedKeys = [
  "locale", "numberingSystem", "style",
  "years", "yearsDisplay", "months", "monthsDisplay",
  "weeks", "weeksDisplay", "days", "daysDisplay",
  "hours", "hoursDisplay", "minutes", "minutesDisplay",
  "seconds", "secondsDisplay", "milliseconds", "millisecondsDisplay",
  "microseconds", "microsecondsDisplay", "nanoseconds", "nanosecondsDisplay",
  "fractionalDigits"
];

function representativeIntlDurationResolvedConsumer(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var formatterIndex = (job + i + lane) & 7;
      var options = representativeIntlDurationResolvedFormatters[formatterIndex].resolvedOptions();
      total = (total + Object.keys(options).length + formatterIndex + i + lane) % 1000000007;
      for (var keyIndex = 0; keyIndex < representativeIntlDurationResolvedKeys.length; keyIndex = keyIndex + 1) {
        var reflected = options[representativeIntlDurationResolvedKeys[keyIndex]];
        if (reflected !== undefined)
          total = (total + representativeIntlDateTimeChecksum("" + reflected) + keyIndex) % 1000000007;
      }
    }
  }
  return total;
}

// Segmenter consumers keep only the immutable formatter and source fixtures
// outside the timed boundary. Each scored Segments object performs its own
// segment() coercion, then consumes every observable record field.
var representativeIntlSegmenter = new Intl.Segmenter("en-US", { granularity: "word" });
var representativeIntlSegmenterInputs = [
  "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu",
  "north south east west spring summer autumn winter morning evening",
  "mercury venus earth mars jupiter saturn uranus neptune ceres pluto",
  "red orange yellow green blue indigo violet silver gold copper bronze",
  "read write execute create update remove inspect validate publish",
  "zero one two three four five six seven eight nine ten eleven twelve",
  "map set weak collection date time locale calendar number duration",
  "secure bounded precise moving shared immutable ordered deterministic"
];

function representativeIntlSegmentRecordChecksum(record) {
  var total = record.index + (record.isWordLike ? 97 : 13);
  total = (total + representativeIntlDateTimeChecksum(record.segment)) % 1000000007;
  total = (total + representativeIntlDateTimeChecksum(record.input)) % 1000000007;
  return total;
}

function representativeIntlSegmenterConsumer(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 16; i = i + 1) {
      var input = representativeIntlSegmenterInputs[(job + i + lane) & 7];
      var segments = representativeIntlSegmenter.segment(input);
      if (kind === "iterate") {
        var iterator = segments[Symbol.iterator]();
        for (;;) {
          var step = iterator.next();
          if (step.done) break;
          total = (total + representativeIntlSegmentRecordChecksum(step.value)) % 1000000007;
        }
      } else {
        for (var probe = 0; probe < 8; probe = probe + 1) {
          var at = (job + i * 7 + probe * 11 + lane) % input.length;
          total = (total + representativeIntlSegmentRecordChecksum(segments.containing(at))) % 1000000007;
        }
      }
    }
  }
  return total;
}

// PluralRules consumers keep formatter construction and fixed numeric inputs
// outside the timed boundary. The select row hashes every returned category;
// the resolved row consumes every category in each fresh reflected array.
var representativeIntlPluralRules = [
  new Intl.PluralRules("en-US"),
  new Intl.PluralRules("ar"),
  new Intl.PluralRules("ru"),
  new Intl.PluralRules("cy"),
  new Intl.PluralRules("en-US", { type: "ordinal" }),
  new Intl.PluralRules("fr", { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
  new Intl.PluralRules("pl", { maximumFractionDigits: 1 }),
  new Intl.PluralRules("en-US", { notation: "scientific" })
];
var representativeIntlPluralValues = [
  0, 1, 2, 3, 4, 5, 6, 10,
  11, 12, 20, 21, 22, 23, 24, 25,
  100, 101, 102, 111, 1000, 1000000, -1, -2,
  0.1, 1.1, 1.2, 2.1, 2.2, 5.5, Infinity, NaN
];

function representativeIntlPluralRulesConsumer(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var iterations = kind === "select" ? 1024 : 512;
    for (var i = 0; i < iterations; i = i + 1) {
      var formatter = representativeIntlPluralRules[(job + i + lane) & 7];
      if (kind === "select") {
        var category = formatter.select(representativeIntlPluralValues[(job * 3 + i + lane) & 31]);
        total = (total + representativeIntlDateTimeChecksum(category) + i + lane) % 1000000007;
      } else {
        var options = formatter.resolvedOptions();
        total = (total + representativeIntlDateTimeChecksum(options.type) +
          representativeIntlDateTimeChecksum(options.notation) + options.pluralCategories.length + i + lane) % 1000000007;
        for (var categoryIndex = 0; categoryIndex < options.pluralCategories.length; categoryIndex = categoryIndex + 1)
          total = (total + representativeIntlDateTimeChecksum(options.pluralCategories[categoryIndex]) + categoryIndex) % 1000000007;
      }
    }
  }
  return total;
}

// DisplayNames steady consumers retain constructed formatters and fixed,
// already-valid codes outside the timed boundary. The selected English
// language/region/script/currency outputs are byte-for-byte equivalent across
// zig-js and the system JSC; broader locale-data differences stay visible in
// the separate correctness child rather than entering this performance row.
var representativeIntlDisplayNamesFormatters = [
  new Intl.DisplayNames("en", { type: "language" }),
  new Intl.DisplayNames("en", { type: "language", languageDisplay: "standard", style: "short" }),
  new Intl.DisplayNames("en", { type: "region" }),
  new Intl.DisplayNames("en", { type: "region", style: "short" }),
  new Intl.DisplayNames("en", { type: "script" }),
  new Intl.DisplayNames("en", { type: "script", style: "short" }),
  new Intl.DisplayNames("en", { type: "currency" }),
  new Intl.DisplayNames("en", { type: "currency", fallback: "none" })
];
var representativeIntlDisplayNamesCodes = [
  ["en", "de", "fr", "ja"],
  ["en", "de", "fr", "ja"],
  ["US", "DE", "FR", "419"],
  ["US", "DE", "FR", "419"],
  ["Latn", "Cyrl", "Arab", "Grek"],
  ["Latn", "Cyrl", "Arab", "Grek"],
  ["USD", "EUR", "JPY", "GBP"],
  ["USD", "EUR", "JPY", "GBP"]
];

function representativeIntlDisplayNamesConsumer(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var call = 0; call < 4096; call = call + 1) {
      var formatterIndex = (job + call + lane) & 7;
      var codeIndex = (job * 3 + call + lane) & 3;
      var output = representativeIntlDisplayNamesFormatters[formatterIndex].of(
        representativeIntlDisplayNamesCodes[formatterIndex][codeIndex]
      );
      total = (total * 131 + representativeIntlDateTimeChecksum(output) + formatterIndex + codeIndex + lane) % 1000000007;
    }
  }
  return total;
}

// DisplayNames reflection keeps construction outside the timed boundary and
// consumes every field from each fresh ordinary result. The formatter matrix
// covers every style/type/fallback choice and conditional languageDisplay.
var representativeIntlDisplayNamesResolvedKeys = [
  "locale", "style", "type", "fallback", "languageDisplay"
];

function representativeIntlDisplayNamesResolvedConsumer(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var formatterIndex = (job + i + lane) & 7;
      var options = representativeIntlDisplayNamesFormatters[formatterIndex].resolvedOptions();
      total = (total + Object.keys(options).length + formatterIndex + i + lane) % 1000000007;
      for (var keyIndex = 0; keyIndex < representativeIntlDisplayNamesResolvedKeys.length; keyIndex = keyIndex + 1) {
        var reflected = options[representativeIntlDisplayNamesResolvedKeys[keyIndex]];
        if (reflected !== undefined)
          total = (total + representativeIntlDateTimeChecksum(reflected) + keyIndex) % 1000000007;
      }
    }
  }
  return total;
}

// Collator steady consumers retain only constructed formatters, their cached
// bound compare functions, and fixed strings outside the timed boundary.
// Direct results are normalized to sign (the ECMA-402 contract); sort hashes
// every output string after executing the public stable Array sort.
var representativeIntlCollators = [
  new Intl.Collator("en-US"),
  new Intl.Collator("en-US", { numeric: true }),
  new Intl.Collator("de-DE-u-co-phonebk"),
  new Intl.Collator("de-DE", { usage: "search", sensitivity: "base" }),
  new Intl.Collator("en-US", { caseFirst: "upper" }),
  new Intl.Collator("en-US", { sensitivity: "base" }),
  new Intl.Collator("th", { ignorePunctuation: true }),
  new Intl.Collator("en-US-u-kn-true-kf-lower")
];
var representativeIntlCollatorComparators = representativeIntlCollators.map(function (collator) {
  return collator.compare;
});
var representativeIntlCollatorSortInputs = [
  ["file2", "file10", "Alpha", "alpha", "resume", "résumé", "a-b", "ab", "Äpfel", "Apfel", "Öl", "Oel", "ångström", "zebra", "東京", "大阪"],
  ["file10", "file2", "item20", "item3", "Alpha", "alpha", "résumé", "resume", "a-b", "ab", "Äpfel", "Apfel", "ångström", "zebra", "東京", "大阪"],
  ["Äpfel", "Apfel", "über", "ueber", "Alpha", "alpha", "resume", "résumé", "a-b", "ab", "file2", "file10", "ångström", "zebra", "東京", "大阪"],
  ["Alpha", "alpha", "resume", "résumé", "Äpfel", "Apfel", "Öl", "Oel", "file2", "file10", "a-b", "ab", "ångström", "zebra", "東京", "大阪"],
  ["alpha", "Alpha", "resume", "résumé", "a-b", "ab", "Äpfel", "Apfel", "Öl", "Oel", "file2", "file10", "ångström", "zebra", "東京", "大阪"],
  ["resume", "résumé", "Alpha", "alpha", "Äpfel", "Apfel", "Öl", "Oel", "file2", "file10", "a-b", "ab", "ångström", "zebra", "東京", "大阪"],
  ["a-b", "ab", "x y", "xy", "Öl", "Oel", "ångström", "zebra", "東京", "大阪"],
  ["file10", "file2", "item20", "item3", "alpha", "Alpha", "resume", "résumé", "a-b", "ab", "Äpfel", "Apfel", "ångström", "zebra", "東京", "大阪"]
];
var representativeIntlCollatorLeft = [
  "file2", "file10", "Alpha", "alpha", "resume", "résumé", "a-b", "ab",
  "Äpfel", "Apfel", "Öl", "Oel", "ångström", "zebra", "東京", "大阪"
];
var representativeIntlCollatorRight = [
  "file10", "file2", "alpha", "Alpha", "résumé", "resume", "ab", "a-b",
  "Apfel", "Äpfel", "Oel", "Öl", "zebra", "ångström", "大阪", "東京"
];
var representativeIntlCollatorPairByComparator = [0, 0, 8, 2, 2, 4, 6, 0];

function representativeIntlCollatorConsumer(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    if (kind === "compare") {
      for (var comparison = 0; comparison < 4096; comparison = comparison + 1) {
        var comparatorIndex = (job + comparison + lane) & 7;
        var pairIndex = representativeIntlCollatorPairByComparator[comparatorIndex];
        var result = representativeIntlCollatorComparators[comparatorIndex](
          representativeIntlCollatorLeft[pairIndex], representativeIntlCollatorRight[pairIndex]
        );
        var sign = result < 0 ? -1 : (result > 0 ? 1 : 0);
        total = (total + (sign + 2) * 131 + comparison + lane) % 1000000007;
      }
    } else {
      for (var sortIndex = 0; sortIndex < 96; sortIndex = sortIndex + 1) {
        var index = (job + sortIndex + lane) & 7;
        var values = representativeIntlCollatorSortInputs[index].slice();
        values.sort(representativeIntlCollatorComparators[index]);
        for (var valueIndex = 0; valueIndex < values.length; valueIndex = valueIndex + 1)
          total = (total * 131 + representativeIntlDateTimeChecksum(values[valueIndex]) + valueIndex + sortIndex + lane) % 1000000007;
      }
    }
  }
  return total;
}

// Collator reflection keeps construction outside the timed boundary and
// consumes every field from each fresh ordinary result. The matrix separates
// default values, explicit options, supported collation, and retained/removed
// Unicode extension keywords without sharing result objects across calls.
var representativeIntlCollatorResolvedFormatters = [
  new Intl.Collator("en-US"),
  new Intl.Collator("en-US", { usage: "search", sensitivity: "base" }),
  new Intl.Collator("en-US", { numeric: true, caseFirst: "upper" }),
  new Intl.Collator("th", { ignorePunctuation: false }),
  new Intl.Collator("de-u-co-phonebk"),
  new Intl.Collator("en-US-u-kn-kf-lower"),
  new Intl.Collator("en-US-u-kn-kf-lower", { numeric: true, caseFirst: "lower" }),
  new Intl.Collator("en-US-u-kn-kf-lower", { numeric: false, caseFirst: "upper" })
];
var representativeIntlCollatorResolvedKeys = [
  "locale", "usage", "sensitivity", "ignorePunctuation",
  "collation", "numeric", "caseFirst"
];

function representativeIntlCollatorResolvedConsumer(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var formatterIndex = (job + i + lane) & 7;
      var options = representativeIntlCollatorResolvedFormatters[formatterIndex].resolvedOptions();
      total = (total + Object.keys(options).length + formatterIndex + i + lane) % 1000000007;
      for (var keyIndex = 0; keyIndex < representativeIntlCollatorResolvedKeys.length; keyIndex = keyIndex + 1) {
        var reflected = options[representativeIntlCollatorResolvedKeys[keyIndex]];
        var reflectedChecksum = typeof reflected === "string"
          ? representativeIntlDateTimeChecksum(reflected)
          : (reflected ? 97 : 31);
        total = (total + reflectedChecksum + keyIndex) % 1000000007;
      }
    }
  }
  return total;
}

// Locale reflection keeps construction/canonicalization outside the timed
// boundary. Every loop consumes the stable tag, each base-name component, and
// every supported Unicode keyword accessor; absent fields and booleans remain
// part of the checksum so an implementation cannot skip sparse state.
var representativeIntlLocaleReflectionLocales = [
  new Intl.Locale("en"),
  new Intl.Locale("zh-Hant-TW"),
  new Intl.Locale("de-DE-1996-u-ca-gregory-co-phonebk-fw-mon-hc-h23-kf-upper-kn-nu-latn"),
  new Intl.Locale("ar-EG-u-ca-islamic-nu-arab"),
  new Intl.Locale("th-TH-u-fw-sun-hc-h24"),
  new Intl.Locale("sr-Cyrl-RS-fonipa-u-kf-lower-kn-false"),
  new Intl.Locale("fr-CA-u-ca-iso8601-co-emoji-nu-latn"),
  new Intl.Locale("ja-JP-u-ca-japanese-fw-tue-hc-h11")
];
var representativeIntlLocaleReflectionKeys = [
  "baseName", "language", "script", "region", "variants", "calendar",
  "caseFirst", "collation", "firstDayOfWeek", "hourCycle", "numeric",
  "numberingSystem"
];

function representativeIntlLocaleReflectionConsumer(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 96; i = i + 1) {
      var localeIndex = (job + i + lane) & 7;
      var locale = representativeIntlLocaleReflectionLocales[localeIndex];
      total = (total + representativeIntlDateTimeChecksum(locale.toString()) + localeIndex + i + lane) % 1000000007;
      for (var keyIndex = 0; keyIndex < representativeIntlLocaleReflectionKeys.length; keyIndex = keyIndex + 1) {
        var reflected = locale[representativeIntlLocaleReflectionKeys[keyIndex]];
        var reflectedChecksum = typeof reflected === "string"
          ? representativeIntlDateTimeChecksum(reflected)
          : (reflected === undefined ? 17 : (reflected ? 97 : 31));
        total = (total + reflectedChecksum + keyIndex) % 1000000007;
      }
    }
  }
  return total;
}

// DateTimeFormat controls separate constructor resolution from steady
// consumers. Keep the fixed UTC inputs and formatter construction outside the
// timed steady boundary so changes to resolved-state ownership are attributable
// without conflating locale-data or clock access.
var representativeIntlDateTimeFormatters = [
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC" }),
  new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC", weekday: "short", year: "numeric", month: "long", day: "numeric"
  }),
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC", dateStyle: "full" }),
  new Intl.DateTimeFormat("de-DE", {
    timeZone: "UTC", year: "numeric", month: "2-digit", day: "2-digit"
  }),
  new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC", hour: "2-digit", minute: "2-digit", second: "2-digit",
    fractionalSecondDigits: 3, hourCycle: "h23"
  }),
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC", dateStyle: "long", timeStyle: "short" }),
  new Intl.DateTimeFormat("en-US-u-nu-latn", {
    timeZone: "UTC", calendar: "gregory", year: "2-digit", month: "2-digit", day: "2-digit"
  }),
  new Intl.DateTimeFormat("en-US", { timeZone: "UTC", year: "numeric", month: "long", day: "numeric" })
];
var representativeIntlDateTimeValues = [
  1704067200000, 1704153600000, 1718409600000, 1735689600000,
  1704112496789, 1718461800000, 1735603200000, 1718409600000
];
// Equal endpoints isolate the two-build/collapse range consumer without
// folding the distinct locale interval-pattern work into resolved-state cost.
var representativeIntlDateTimeEnds = [
  1704067200000, 1704153600000, 1718409600000, 1735689600000,
  1704112496789, 1718461800000, 1735603200000, 1718409600000
];

function representativeIntlDateTimeChecksum(text) {
  var total = text.length;
  for (var index = 0; index < text.length; index = index + 1)
    total = (total * 131 + text.charCodeAt(index)) % 1000000007;
  return total;
}

function representativeIntlDateTimeFormatConsumer(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 64; i = i + 1) {
      var index = (job + i + lane) & 7;
      var formatter = representativeIntlDateTimeFormatters[index];
      if (kind === "text") {
        total = (total + representativeIntlDateTimeChecksum(formatter.format(representativeIntlDateTimeValues[index]))) % 1000000007;
      } else if (kind === "parts") {
        var parts = formatter.formatToParts(representativeIntlDateTimeValues[index]);
        for (var part = 0; part < parts.length; part = part + 1) {
          total = (total + representativeIntlDateTimeChecksum(parts[part].type) +
            representativeIntlDateTimeChecksum(parts[part].value)) % 1000000007;
        }
      } else if (kind === "range") {
        total = (total + representativeIntlDateTimeChecksum(formatter.formatRange(
          representativeIntlDateTimeValues[index], representativeIntlDateTimeEnds[index]
        ))) % 1000000007;
      } else {
        var rangeParts = formatter.formatRangeToParts(
          representativeIntlDateTimeValues[index], representativeIntlDateTimeEnds[index]
        );
        for (var rangePart = 0; rangePart < rangeParts.length; rangePart = rangePart + 1) {
          total = (total + representativeIntlDateTimeChecksum(rangeParts[rangePart].type) +
            representativeIntlDateTimeChecksum(rangeParts[rangePart].value) +
            representativeIntlDateTimeChecksum(rangeParts[rangePart].source)) % 1000000007;
        }
      }
    }
  }
  return total;
}

function representativeIntlDateTimeFormatConstruct(jobs, lane, kind) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var i = 0; i < 32; i = i + 1) {
      var formatter;
      if (kind === "default") {
        formatter = new Intl.DateTimeFormat("en-US", { timeZone: "UTC" });
      } else if (kind === "components") {
        formatter = new Intl.DateTimeFormat("en-US", {
          timeZone: "UTC", fractionalSecondDigits: 3, second: "2-digit", minute: "2-digit",
          hour: "2-digit", day: "numeric", month: "long", year: "numeric", weekday: "short",
          hourCycle: "h23"
        });
      } else if (kind === "style") {
        formatter = new Intl.DateTimeFormat("en-US", {
          timeZone: "UTC", timeStyle: "long", dateStyle: "full"
        });
      } else {
        formatter = new Intl.DateTimeFormat("de-DE-u-nu-latn", {
          timeZone: "UTC", hour12: false, calendar: "gregory", numberingSystem: "latn",
          year: "2-digit", month: "2-digit", day: "2-digit"
        });
      }
      var options = formatter.resolvedOptions();
      total = (total + representativeIntlDateTimeChecksum(options.locale) +
        representativeIntlDateTimeChecksum(options.calendar) +
        representativeIntlDateTimeChecksum(options.numberingSystem) +
        representativeIntlDateTimeChecksum(options.timeZone) + lane + (job & 3)) % 1000000007;
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
  if (name === "representative_regexp_search_ascii") return function (jobs, lane) { return representativeRegExpSearchInput(jobs, lane, "ascii"); };
  if (name === "representative_regexp_search_bmp") return function (jobs, lane) { return representativeRegExpSearchInput(jobs, lane, "bmp"); };
  if (name === "representative_regexp_search_astral") return function (jobs, lane) { return representativeRegExpSearchInput(jobs, lane, "astral"); };
  if (name === "representative_regexp_search_lone_surrogate") return function (jobs, lane) { return representativeRegExpSearchInput(jobs, lane, "lone"); };
  if (name === "representative_text_encoder_ascii") return function (jobs, lane) { return representativeTextEncoderBoundary(jobs, lane, "ascii"); };
  if (name === "representative_text_encoder_unicode") return function (jobs, lane) { return representativeTextEncoderBoundary(jobs, lane, "unicode"); };
  if (name === "representative_text_encoder_lone_surrogate") return function (jobs, lane) { return representativeTextEncoderBoundary(jobs, lane, "lone"); };
  if (name === "representative_text_encoder_paired_surrogates") return function (jobs, lane) { return representativeTextEncoderBoundary(jobs, lane, "pair"); };
  if (name === "representative_json") return function (jobs, lane) { return representativeJson(jobs, lane, 0); };
  if (name === "representative_json_variant") return function (jobs, lane) { return representativeJson(jobs, lane, 1); };
  if (name === "representative_json_reviver_source") return representativeJsonReviverSource;
  if (name === "representative_json_escaped_strings") return representativeJsonEscapedStrings;
  if (name === "representative_json_stringify_replacer") return representativeJsonStringifyReplacer;
  if (name === "representative_json_stringify_replacer_membership") return representativeJsonStringifyReplacerMembership;
  if (name === "representative_json_stringify_depth_512") return selectRepresentativeJsonStringifyDepth(512, false);
  if (name === "representative_json_stringify_depth_1024") return selectRepresentativeJsonStringifyDepth(1024, false);
  if (name === "representative_json_stringify_depth_2048") return selectRepresentativeJsonStringifyDepth(2048, false);
  if (name === "representative_json_stringify_depth_4096") return selectRepresentativeJsonStringifyDepth(4096, false);
  if (name === "representative_json_stringify_cycle_4096") return selectRepresentativeJsonStringifyDepth(4096, true);
  if (name === "representative_json_stringify_shallow_4096") return selectRepresentativeJsonStringifyShallow(4096);
  if (name === "representative_json_stringify_plain_4096") return selectRepresentativeJsonStringifyString("plain", 4096);
  if (name === "representative_json_stringify_plain_16384") return selectRepresentativeJsonStringifyString("plain", 16384);
  if (name === "representative_json_stringify_plain_65536") return selectRepresentativeJsonStringifyString("plain", 65536);
  if (name === "representative_json_stringify_unicode_4096") return selectRepresentativeJsonStringifyString("unicode", 4096);
  if (name === "representative_json_stringify_sparse_escapes_65536") return selectRepresentativeJsonStringifyString("sparse", 4096);
  if (name === "representative_json_stringify_lone_surrogates_4096") return selectRepresentativeJsonStringifyString("surrogate", 1024);
  if (name === "representative_json_stringify_short_control") return selectRepresentativeJsonStringifyString("short", 0);
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
  if (name === "representative_date_string_1024") return selectRepresentativeDateString(1024, false);
  if (name === "representative_date_string_2048") return selectRepresentativeDateString(2048, false);
  if (name === "representative_date_string_4096") return selectRepresentativeDateString(4096, false);
  if (name === "representative_date_getter_control_4096") return selectRepresentativeDateString(4096, true);
  if (name === "representative_locale_list_8") return selectRepresentativeLocaleList(8, false);
  if (name === "representative_locale_list_1024") return selectRepresentativeLocaleList(1024, false);
  if (name === "representative_locale_list_2048") return selectRepresentativeLocaleList(2048, false);
  if (name === "representative_locale_list_4096") return selectRepresentativeLocaleList(4096, false);
  if (name === "representative_locale_list_duplicates_4096") return selectRepresentativeLocaleList(4096, true);
  if (name === "representative_array_like_1024") return selectRepresentativeArrayTraversal(1024, "generic");
  if (name === "representative_array_like_2048") return selectRepresentativeArrayTraversal(2048, "generic");
  if (name === "representative_array_like_4096") return selectRepresentativeArrayTraversal(4096, "generic");
  if (name === "representative_array_like_sparse_proxy_4096") return selectRepresentativeArrayTraversal(4096, "proxy");
  if (name === "representative_array_dense_control_4096") return selectRepresentativeArrayTraversal(4096, "dense");
  if (name === "representative_shape_transition_fanout") return selectRepresentativeShapeTransitionFanout(0, false);
  if (name === "representative_shape_transition_fanout_variant") return selectRepresentativeShapeTransitionFanout(1, false);
  if (name === "representative_shape_transition_fanout_contended") return selectRepresentativeShapeTransitionFanout(0, true);
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
  if (name === "representative_intl_number_format_steady_default") return function (jobs, lane) { return representativeIntlNumberFormatSteady(jobs, lane, "default"); };
  if (name === "representative_intl_number_format_steady_fraction") return function (jobs, lane) { return representativeIntlNumberFormatSteady(jobs, lane, "fraction"); };
  if (name === "representative_intl_number_format_steady_locale") return function (jobs, lane) { return representativeIntlNumberFormatSteady(jobs, lane, "locale"); };
  if (name === "representative_intl_number_format_steady_uncommon") return function (jobs, lane) { return representativeIntlNumberFormatSteady(jobs, lane, "uncommon"); };
  if (name === "representative_intl_number_format_construct_default") return function (jobs, lane) { return representativeIntlNumberFormatConstruct(jobs, lane, "default"); };
  if (name === "representative_intl_number_format_construct_fraction") return function (jobs, lane) { return representativeIntlNumberFormatConstruct(jobs, lane, "fraction"); };
  if (name === "representative_intl_number_format_construct_locale") return function (jobs, lane) { return representativeIntlNumberFormatConstruct(jobs, lane, "locale"); };
  if (name === "representative_intl_number_format_construct_uncommon") return function (jobs, lane) { return representativeIntlNumberFormatConstruct(jobs, lane, "uncommon"); };
  if (name === "representative_intl_number_format_consumer_text") return function (jobs, lane) { return representativeIntlNumberFormatConsumer(jobs, lane, "text"); };
  if (name === "representative_intl_number_format_consumer_parts") return function (jobs, lane) { return representativeIntlNumberFormatConsumer(jobs, lane, "parts"); };
  if (name === "representative_intl_number_format_consumer_range") return function (jobs, lane) { return representativeIntlNumberFormatConsumer(jobs, lane, "range"); };
  if (name === "representative_intl_number_format_consumer_range_parts") return function (jobs, lane) { return representativeIntlNumberFormatConsumer(jobs, lane, "rangeParts"); };
  if (name === "representative_intl_number_format_rounding_text") return function (jobs, lane) { return representativeIntlNumberFormatRounding(jobs, lane, false); };
  if (name === "representative_intl_number_format_rounding_parts") return function (jobs, lane) { return representativeIntlNumberFormatRounding(jobs, lane, true); };
  if (name === "representative_intl_number_format_compact_text") return function (jobs, lane) { return representativeIntlNumberFormatCompact(jobs, lane, false); };
  if (name === "representative_intl_number_format_compact_parts") return function (jobs, lane) { return representativeIntlNumberFormatCompact(jobs, lane, true); };
  if (name === "representative_intl_number_format_bigint_text") return function (jobs, lane) { return representativeIntlNumberFormatBigInt(jobs, lane, "text"); };
  if (name === "representative_intl_number_format_bigint_parts") return function (jobs, lane) { return representativeIntlNumberFormatBigInt(jobs, lane, "parts"); };
  if (name === "representative_intl_number_format_bigint_range") return function (jobs, lane) { return representativeIntlNumberFormatBigInt(jobs, lane, "range"); };
  if (name === "representative_intl_number_format_bigint_range_parts") return function (jobs, lane) { return representativeIntlNumberFormatBigInt(jobs, lane, "rangeParts"); };
  if (name === "representative_intl_number_format_compact_cldr_text") return function (jobs, lane) { return representativeIntlNumberFormatCompactCldr(jobs, lane, "text"); };
  if (name === "representative_intl_number_format_compact_cldr_parts") return function (jobs, lane) { return representativeIntlNumberFormatCompactCldr(jobs, lane, "parts"); };
  if (name === "representative_intl_number_format_compact_cldr_range") return function (jobs, lane) { return representativeIntlNumberFormatCompactCldr(jobs, lane, "range"); };
  if (name === "representative_intl_number_format_compact_cldr_range_parts") return function (jobs, lane) { return representativeIntlNumberFormatCompactCldr(jobs, lane, "rangeParts"); };
  if (name === "representative_intl_number_format_currency_name_cldr_text") return function (jobs, lane) { return representativeIntlNumberFormatCurrencyNameCldr(jobs, lane, "text"); };
  if (name === "representative_intl_number_format_currency_name_cldr_parts") return function (jobs, lane) { return representativeIntlNumberFormatCurrencyNameCldr(jobs, lane, "parts"); };
  if (name === "representative_intl_number_format_currency_name_cldr_range") return function (jobs, lane) { return representativeIntlNumberFormatCurrencyNameCldr(jobs, lane, "range"); };
  if (name === "representative_intl_number_format_currency_name_cldr_range_parts") return function (jobs, lane) { return representativeIntlNumberFormatCurrencyNameCldr(jobs, lane, "rangeParts"); };
  if (name === "representative_intl_number_format_numbering_system_cldr_text") return function (jobs, lane) { return representativeIntlNumberFormatNumberingSystemCldr(jobs, lane, "text"); };
  if (name === "representative_intl_number_format_numbering_system_cldr_parts") return function (jobs, lane) { return representativeIntlNumberFormatNumberingSystemCldr(jobs, lane, "parts"); };
  if (name === "representative_intl_number_format_numbering_system_cldr_range") return function (jobs, lane) { return representativeIntlNumberFormatNumberingSystemCldr(jobs, lane, "range"); };
  if (name === "representative_intl_number_format_numbering_system_cldr_resolved") return function (jobs, lane) { return representativeIntlNumberFormatNumberingSystemCldr(jobs, lane, "resolved"); };
  if (name === "representative_intl_list_format_parts") return function (jobs, lane) { return representativeIntlStructuralService(jobs, lane, "list"); };
  if (name === "representative_intl_relative_time_format_parts") return function (jobs, lane) { return representativeIntlStructuralService(jobs, lane, "relative"); };
  if (name === "representative_intl_duration_format_parts") return function (jobs, lane) { return representativeIntlStructuralService(jobs, lane, "duration"); };
  if (name === "representative_intl_duration_format_resolved") return representativeIntlDurationResolvedConsumer;
  if (name === "representative_intl_segmenter_iterate_word") return function (jobs, lane) { return representativeIntlSegmenterConsumer(jobs, lane, "iterate"); };
  if (name === "representative_intl_segmenter_containing_word") return function (jobs, lane) { return representativeIntlSegmenterConsumer(jobs, lane, "containing"); };
  if (name === "representative_intl_plural_rules_select") return function (jobs, lane) { return representativeIntlPluralRulesConsumer(jobs, lane, "select"); };
  if (name === "representative_intl_plural_rules_resolved_categories") return function (jobs, lane) { return representativeIntlPluralRulesConsumer(jobs, lane, "resolved"); };
  if (name === "representative_intl_display_names_of") return representativeIntlDisplayNamesConsumer;
  if (name === "representative_intl_display_names_resolved") return representativeIntlDisplayNamesResolvedConsumer;
  if (name === "representative_intl_collator_compare") return function (jobs, lane) { return representativeIntlCollatorConsumer(jobs, lane, "compare"); };
  if (name === "representative_intl_collator_sort") return function (jobs, lane) { return representativeIntlCollatorConsumer(jobs, lane, "sort"); };
  if (name === "representative_intl_collator_resolved") return representativeIntlCollatorResolvedConsumer;
  if (name === "representative_intl_locale_reflection") return representativeIntlLocaleReflectionConsumer;
  if (name === "representative_intl_date_time_format_consumer_text") return function (jobs, lane) { return representativeIntlDateTimeFormatConsumer(jobs, lane, "text"); };
  if (name === "representative_intl_date_time_format_consumer_parts") return function (jobs, lane) { return representativeIntlDateTimeFormatConsumer(jobs, lane, "parts"); };
  if (name === "representative_intl_date_time_format_consumer_range") return function (jobs, lane) { return representativeIntlDateTimeFormatConsumer(jobs, lane, "range"); };
  if (name === "representative_intl_date_time_format_consumer_range_parts") return function (jobs, lane) { return representativeIntlDateTimeFormatConsumer(jobs, lane, "rangeParts"); };
  if (name === "representative_intl_date_time_format_construct_default") return function (jobs, lane) { return representativeIntlDateTimeFormatConstruct(jobs, lane, "default"); };
  if (name === "representative_intl_date_time_format_construct_components") return function (jobs, lane) { return representativeIntlDateTimeFormatConstruct(jobs, lane, "components"); };
  if (name === "representative_intl_date_time_format_construct_style") return function (jobs, lane) { return representativeIntlDateTimeFormatConstruct(jobs, lane, "style"); };
  if (name === "representative_intl_date_time_format_construct_locale") return function (jobs, lane) { return representativeIntlDateTimeFormatConstruct(jobs, lane, "locale"); };
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
