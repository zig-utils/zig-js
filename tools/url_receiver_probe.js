// URL/Web IDL receiver checks, including copied component slots and proxies.
// Node 26.10 converts href setter inputs before rejecting invalid receivers:
// it scores 288/296 here; Bun 1.4.4 follows Web IDL and scores 296/296.
let passed = 0;
let checks = 0;
function check(condition) {
  checks++;
  if (condition) passed++;
}
const real = new URL('https://user:pass@example.com:8443/path?x=1#part');
const properties = ['href', 'origin', 'protocol', 'username', 'password', 'host', 'hostname', 'port', 'pathname', 'search', 'searchParams', 'hash'];
const expected = ['https://user:pass@example.com:8443/path?x=1#part', 'https://example.com:8443', 'https:', 'user', 'pass', 'example.com:8443', 'example.com', '8443', '/path', '?x=1', 'x=1', '#part'];
const copied = Object.create(URL.prototype);
Object.defineProperties(copied, Object.getOwnPropertyDescriptors(real));
const receivers = [{}, Object.create(URL.prototype), URL.prototype, null, undefined, 1, new Proxy(real, {}), copied];
for (let propertyIndex = 0; propertyIndex < properties.length; propertyIndex++) {
  const property = properties[propertyIndex];
  const descriptor = Object.getOwnPropertyDescriptor(URL.prototype, property);
  const actual = descriptor.get.call(real);
  check((property === 'searchParams' ? actual.toString() : actual) === expected[propertyIndex]);
  for (const receiver of receivers) {
    let error;
    try {
      descriptor.get.call(receiver);
    }
    catch (caught) {
      error = caught;
    }
    check(error instanceof TypeError);
    if (descriptor.set) {
      let conversions = 0;
      const argument = { toString: function() {
        conversions++;
        return 'https://evil.invalid/';
      } };
      error = undefined;
      try {
        descriptor.set.call(receiver, argument);
      }
      catch (caught) {
        error = caught;
      }
      check(error instanceof TypeError);
      check(conversions === 0);
    }
  }
}
for (const method of ['toString', 'toJSON']) {
  for (const receiver of receivers) {
    let error;
    try {
      URL.prototype[method].call(receiver);
    }
    catch (caught) {
      error = caught;
    }
    check(error instanceof TypeError);
  }
}
check(real.href === expected[0]);
const valid = new URL('https://example.com/');
const params = valid.searchParams;
const assignments = [['href', expected[0]], ['protocol', 'http:'], ['username', 'alice'], ['password', 'secret'], ['host', 'example.org:8080'], ['hostname', 'example.net'], ['port', '9090'], ['pathname', '/new-path'], ['search', '?next=2'], ['hash', '#tail']];
for (const assignment of assignments) {
  const descriptor = Object.getOwnPropertyDescriptor(URL.prototype, assignment[0]);
  descriptor.set.call(valid, assignment[1]);
  check(descriptor.get.call(valid) === assignment[1]);
}
check(valid.searchParams === params && params.get('next') === '2');
if (checks !== 296) throw new Error('URL receiver check inventory changed');
return passed;
