// Unescaped control for json_parse_escaped.js; identical length and checksum.
var width = 65536;
var chunk = "abcdefghijklmnopqrstuvwxyz012345";
var plain = chunk.repeat(width / chunk.length);
var text = '"' + plain + 'n' + plain + '"';
var sum = 0;
for (var i = 0; i < 256; i++) {
  var parsed = JSON.parse(text);
  if (parsed.length !== width * 2 + 1 || parsed.charCodeAt(width) !== 110) throw new Error("bad result");
  sum += parsed.length + parsed.charCodeAt(0) + parsed.charCodeAt(parsed.length - 1);
}
sum;
