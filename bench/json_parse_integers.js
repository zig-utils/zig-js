// Diagnostic integer conversion workload; pair with json_parse_decimals.js.
var fields = [];
for (var i = 0; i < 4096; i++) fields.push(String(123456789 + i));
var text = '[' + fields.join(',') + ']';
var sum = 0;
for (var i = 0; i < 512; i++) {
  var parsed = JSON.parse(text);
  if (parsed.length !== 4096 || parsed[0] !== 123456789 || parsed[4095] !== 123460884) throw new Error("bad result");
  sum += parsed.length + parsed[0] + parsed[4095];
}
sum;
