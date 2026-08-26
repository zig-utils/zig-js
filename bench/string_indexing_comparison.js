// Non-scored UTF-16 indexing growth witnesses for #767. Fixture construction
// happens while benchmarkFunction selects a row, before the runner's warmups
// and timed invocation. Every scored iteration reads the same immutable string
// through the String builtin, primitive exotic, and boxed exotic paths.

var representativeStringIndexValue = "";
var representativeStringIndexBoxed = null;
var representativeStringIndexWidth = 0;

function representativeStringIndexPattern(kind) {
  if (kind === "ascii") return "Ax";
  if (kind === "latin1") return "éÿ";
  if (kind === "bmp") return "水Ω";
  if (kind === "astral") return "😀";
  if (kind === "lone") return "\ud800x";
  if (kind === "mixed") return "Aé水😀\ud800x";
  throw new Error("unknown string indexing representation: " + kind);
}

function selectRepresentativeStringIndex(kind, width) {
  var pattern = representativeStringIndexPattern(kind);
  var pieces = [];
  var units = 0;
  while (units < width) {
    pieces.push(pattern);
    units = units + pattern.length;
  }
  var value = pieces.join("");
  if (value.length !== width) value = value.slice(0, width);
  if (value.length !== width)
    throw new Error("string indexing fixture width drift: " + value.length + " != " + width);
  representativeStringIndexValue = value;
  representativeStringIndexBoxed = new String(value);
  representativeStringIndexWidth = width;
  return representativeStringIndex;
}

function representativeStringIndex(jobs, lane) {
  var value = representativeStringIndexValue;
  var boxed = representativeStringIndexBoxed;
  var width = representativeStringIndexWidth;
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    for (var index = 0; index < width; index = index + 1) {
      var expected = value.charCodeAt(index);
      var primitive = value[index];
      var wrapped = boxed[index];
      var primitiveUnit = primitive.charCodeAt(0);
      var wrappedUnit = wrapped.charCodeAt(0);
      if (primitiveUnit !== expected || wrappedUnit !== expected)
        throw new Error("string indexing path disagreement at " + index);
      total = total + expected + primitiveUnit + wrappedUnit +
        (index & 7) + lane + (job & 3);
    }
    // Length is an exotic property too. Keep this separate from the index loop
    // so the frozen work exposes repeated length resolution without making the
    // loop bound itself representation-dependent.
    for (var probe = 0; probe < width; probe = probe + 1)
      total = total + value.length + boxed.length + (probe & 3);

    var middle = width >> 1;
    var middleUnit = value.charAt(middle).charCodeAt(0);
    var finalUnit = value.at(-1).charCodeAt(0);
    var point = value.codePointAt(middle);
    total = total + middleUnit + finalUnit + point;
  }
  return total;
}

function benchmarkFunction(name) {
  var prefix = "representative_string_utf16_";
  if (name.indexOf(prefix) !== 0)
    throw new Error("unknown string indexing workload: " + name);
  var suffix = name.slice(prefix.length);
  var separator = suffix.lastIndexOf("_");
  if (separator <= 0)
    throw new Error("invalid string indexing workload: " + name);
  var kind = suffix.slice(0, separator);
  var width = Number(suffix.slice(separator + 1));
  if ((width !== 1024 && width !== 2048 && width !== 4096) ||
      (kind !== "ascii" && kind !== "latin1" && kind !== "bmp" &&
       kind !== "astral" && kind !== "lone" && kind !== "mixed"))
    throw new Error("invalid string indexing workload: " + name);
  return selectRepresentativeStringIndex(kind, width);
}
