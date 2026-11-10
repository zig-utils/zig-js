// Exact BCP-47 expression from @stacksjs/ts-validation 0.5.7.
// Captured separator alternatives must compile as their character-class peers.
// ECMA-262 RegExpBuiltinExec capture, lastIndex and substitution semantics.
var source = "(^(x(-[A-Za-z0-9]{1,8})+)$)|(^(((en-GB-oed)|(i-ami)|(i-bnn)|(i-default)|(i-enochian)|(i-hak)|(i-klingon)|(i-lux)|(i-mingo)|(i-navajo)|(i-pwn)|(i-tao)|(i-tay)|(i-tsu)|(sgn-BE-FR)|(sgn-BE-NL)|(sgn-CH-DE))|((art-lojban)|(cel-gaulish)|(no-bok)|(no-nyn)|(zh-guoyu)|(zh-hakka)|(zh-min)|(zh-min-nan)|(zh-xiang)))$)|(^(([a-zA-Z]{2,3}(-([A-Za-z]{3}(-[A-Za-z]{3}){0,2}))?)|([a-zA-Z]{5,8}))((-|_)([A-Za-z]{4}))?((-|_)([A-Za-z]{2}|\\d{3}))?((-|_)([A-Za-z0-9]{5,8}|(\\d[A-Z-a-z0-9]{3})))*((-|_)((\\d|[A-W]|[Y-Z]|[a-w]|[y-z])(-[A-Za-z0-9]{2,8})+))*((-|_)(x(-[A-Za-z0-9]{1,8})+))?$)";
var checks = 0;
function check(ok, label) { checks++; if (!ok) throw Error(label); }
var samples = [{"input": "en", "expected": true}, {"input": "en-US", "expected": true}, {"input": "en-GB-oed", "expected": true}, {"input": "x-private", "expected": true}, {"input": "en-a-foobar", "expected": true}, {"input": "en_a-foobar", "expected": true}, {"input": "zh-Hans-CN", "expected": true}, {"input": "de-CH-1901", "expected": true}, {"input": "", "expected": false}, {"input": "en-", "expected": false}, {"input": "en--US", "expected": false}, {"input": "en-a", "expected": false}, {"input": "en-a-b", "expected": false}, {"input": "_en", "expected": false}, {"input": "en-abcdefghi", "expected": false}, {"input": "x-", "expected": false}, {"input": "fr_Latn_FR", "expected": true}, {"input": "i-klingon", "expected": true}, {"input": "sgn-BE-FR", "expected": true}, {"input": "en-US-x-hello", "expected": true}, {"input": "en-1234", "expected": true}, {"input": "en-a-12345678", "expected": true}, {"input": "en-a-123456789", "expected": false}];
var captures = [{"input": "en-US", "expected": ["en-US", null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, "en-US", "en", "en", null, null, null, null, null, null, null, "-US", "-", "US", null, null, null, null, null, null, null, null, null, null, null, null, null]}, {"input": "en-GB-oed", "expected": ["en-GB-oed", null, null, null, "en-GB-oed", "en-GB-oed", "en-GB-oed", "en-GB-oed", null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null]}, {"input": "en_a-foobar", "expected": ["en_a-foobar", null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, "en_a-foobar", "en", "en", null, null, null, null, null, null, null, null, null, null, null, null, null, null, "_a-foobar", "_", "a-foobar", "a", "-foobar", null, null, null, null]}];
for (var flags of ["", "u", "i", "iu"]) {
    var re = new RegExp(source, flags);
    for (var sample of samples) check(re.test(sample.input) === sample.expected, "language tag " + flags + ": " + sample.input);
    for (var sample of captures) {
        var m = re.exec(sample.input);
        check(m !== null && m.index === 0 && m.input === sample.input, "capture input");
        check(m.length === 60, "all 59 capture slots retained");
        for (var i = 0; i < 60; i++) check(m[i] === (sample.expected[i] === null ? undefined : sample.expected[i]), "capture " + i);
    }
}
for (var flags of ["g", "gu", "y", "yu", "d", "du"]) {
    var re = new RegExp(source, flags);
    var m = re.exec("en-US");
    check(m !== null && m[0] === "en-US" && m.length === 60, "flag captures " + flags);
    if (flags.indexOf("g") !== -1 || flags.indexOf("y") !== -1) {
        check(re.lastIndex === 5, "successful lastIndex " + flags);
        check(re.exec("en-US") === null && re.lastIndex === 0, "failed lastIndex reset " + flags);
    }
    if (flags.indexOf("d") !== -1) check(m.indices[0][0] === 0 && m.indices[0][1] === 5, "match indices " + flags);
}
var alt = new RegExp("^((-|_)(a(-[a-z]{2,8})+))*$");
var cls = new RegExp("^([-_](a(-[a-z]{2,8})+))*$");
for (var input of ["", "-a-ab", "_a-xy-ab", "-a-a", "aa", "_a-xy-a-zz"]) check(alt.test(input) === cls.test(input), "separator equivalence " + input);
check("en-US".replace(new RegExp(source), function () {
    check(arguments.length === 62 && arguments[0] === "en-US" && arguments[60] === 0 && arguments[61] === "en-US", "replace capture arguments");
    return "validated";
}) === "validated", "replacement");
return checks;
