// Fractional control: still requires the general correctly rounded converter.
var fields = [];
for (var i = 0; i < 4096; i++) fields.push(String(123456789 + i) + '.5');
var text = '[' + fields.join(',') + ']';
var sum = 0;
for (var i = 0; i < 512; i++) {
  var parsed = JSON.parse(text);
  if (parsed.length !== 4096 || parsed[0] !== 123456789.5 || parsed[4095] !== 123460884.5) throw new Error("bad result");
  sum += parsed.length + parsed[0] + parsed[4095];
}
sum;
