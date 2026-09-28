// Diagnostic workload for #991; pair with json_parse_plain.js, same runner/mode.
// Process startup and source preparation are included; not a JSC score.
var width = 65536;
var chunk = "abcdefghijklmnopqrstuvwxyz012345";
var plain = chunk.repeat(width / chunk.length);
var text = '"' + plain + '\\n' + plain + '"';
var sum = 0;
for (var i = 0; i < 256; i++) {
  var parsed = JSON.parse(text);
  if (parsed.length !== width * 2 + 1 || parsed.charCodeAt(width) !== 10) throw new Error("bad result");
  sum += parsed.length + parsed.charCodeAt(0) + parsed.charCodeAt(parsed.length - 1);
}
sum;
