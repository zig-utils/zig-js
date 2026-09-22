//! Small semantic gates for frontend, VM, and concurrency development (#53,
//! #494).
//!
//! This is an executable rather than a Zig test root: importing `vm.zig`
//! through `zig test` recursively discovers the interpreter, Thread, Context,
//! and C-API integration tests. Executable builds use the exact production
//! `js` module without linking hundreds of unrelated test declarations.

const std = @import("std");
const js = @import("js");

const Case = struct {
    name: []const u8,
    source: []const u8,
    expected: f64,
};

const ErrorCase = struct {
    name: []const u8,
    source: []const u8,
};

const frontend_cases = [_]Case{
    .{
        .name = "dynamic function bodies cannot escape their synthesized boundary",
        .source =
        \\var GeneratorFunction = Object.getPrototypeOf(function*(){}).constructor;
        \\var AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
        \\var AsyncGeneratorFunction = Object.getPrototypeOf(async function*(){}).constructor;
        \\var constructors = [Function, GeneratorFunction, AsyncFunction, AsyncGeneratorFunction];
        \\var bodies = [
        \\  '}); globalThis.injected = 1; (function(){',
        \\  '}, function(){ return "inj" ',
        \\  '}, function(){',
        \\  '})(); (function(){'
        \\];
        \\globalThis.injected = 0;
        \\var rejected = 0;
        \\for (var i = 0; i < constructors.length; i++) {
        \\  for (var j = 0; j < bodies.length; j++) {
        \\    try { constructors[i](bodies[j]); }
        \\    catch (e) { if (e instanceof SyntaxError) rejected++; }
        \\  }
        \\}
        \\var valid = 0;
        \\for (var k = 0; k < constructors.length; k++) {
        \\  try { constructors[k]('return 1; // trailing'); valid++; } catch (e) {}
        \\  try { constructors[k]('--> leading comment\\nreturn 1;'); valid++; } catch (e) {}
        \\}
        \\rejected === 16 && globalThis.injected === 0 && valid === 8 ? 1 : 0
        ,
        .expected = 1,
    },
    .{
        .name = "statement and control flow SyntaxErrors retain JSC prose",
        .source =
        \\var rows = [
        \\  ["if (true) let [a] = [];", "Unexpected token '['. Cannot use lexical declaration in single-statement context."],
        \\  ["if (true) const x = 1;", "Unexpected keyword 'const'"],
        \\  ["if (true) class C {}", "Unexpected keyword 'class'. 'class' declaration is not directly within a block statement."],
        \\  ["\"use strict\"; with ({}) {}", "'with' statements are not valid in strict mode."],
        \\  ["break;", "'break' is only valid inside a switch or loop statement."],
        \\  ["break missing;", "Cannot use the undeclared label 'missing'."],
        \\  ["continue;", "'continue' is only valid inside a loop statement."],
        \\  ["continue missing;", "Cannot use the undeclared label 'missing'."],
        \\  ["outer: { continue outer; }", "Cannot continue to the label 'outer' as it is not targeting a loop."],
        \\  ["label: label: ;", "Unexpected token ';'. Attempted to redeclare the label 'label'."],
        \\  ["if (true) function* g() {}", "Unexpected token '*'. Cannot use generator function declaration in single-statement context."],
        \\  ["if (true) async function f() {}", "Unexpected keyword 'function'. Cannot use async function declaration in single-statement context."],
        \\  ["\"use strict\"; if (true) function f() {}", "Function declarations are only allowed inside blocks or switch statements in strict mode."],
        \\  ["while (false) function f() {}", "Unexpected keyword 'function'. Function declarations are only allowed inside block statements or at the top level of a program."],
        \\  ["if (true) label: function f() {}", "Unexpected keyword 'function'. Function declarations are only allowed inside block statements or at the top level of a program."],
        \\];
        \\rows.reduce(function(bits, row, i) {
        \\  try { eval(row[0]); return bits; }
        \\  catch (error) { return error instanceof SyntaxError && error.message === row[1] ? bits | (1 << i) : bits; }
        \\}, 0)
        ,
        .expected = 32767,
    },
    .{
        .name = "binding and parameter SyntaxErrors retain JSC prose",
        .source =
        \\var rows = [
        \\  ["function f(a) { let a; }", "Cannot declare a let variable twice: 'a'."],
        \\  ["function f({a}) { const a = 1; }", "Cannot declare a const variable twice: 'a'."],
        \\  ["function f(a) { const a = 1, b = 2; }", "Cannot declare a const variable twice: 'a'."],
        \\  ["function f(a) { class a {} }", "Cannot declare a class twice: 'a'."],
        \\  ["(a) => { let a; }", "Cannot declare a let variable twice: 'a'."],
        \\  ["try {} catch ([e, e]) {}", "Unexpected identifier 'e'. Cannot declare a lexical variable twice: 'e'."],
        \\  ["try {} catch (e) { let e; }", "Cannot declare a let variable twice: 'e'."],
        \\  ["try {} catch ({e}) { const {e} = {}; }", "Unexpected token '}'. Cannot declare a lexical variable twice: 'e'."],
        \\  ["try {} catch (e) { const e = 1, x = 2; }", "Cannot declare a const variable twice: 'e'."],
        \\  ["try {} catch (e) { function e() {} }", "Cannot declare a function that shadows a let/const/class/function variable 'e'."],
        \\  ["try {} catch (e) { class e {} }", "Cannot declare a class twice: 'e'."],
        \\  ["function f(eval) { \"use strict\"; }", "Invalid parameters or function name in strict mode."],
        \\  ["function f(a, a) { \"use strict\"; }", "Invalid parameters or function name in strict mode."],
        \\  ["function () {}", "Function statements must have a name."],
        \\  ["function if() {}", "Cannot use the keyword 'if' as a function name."],
        \\  ["function f(a = 1) { \"use strict\"; }", "'use strict' directive not allowed inside a function with a non-simple parameter list."],
        \\  ["\"use strict\"; function eval() {}", "'eval' is not a valid function name in strict mode."],
        \\  ["function arguments() { \"use strict\"; }", "'arguments' is not a valid function name in strict mode."],
        \\];
        \\rows.reduce(function(bits, row, i) {
        \\  try { eval(row[0]); return bits; }
        \\  catch (error) { return error instanceof SyntaxError && error.message === row[1] ? bits | (1 << i) : bits; }
        \\}, 0)
        ,
        .expected = 262143,
    },
    .{
        .name = "object and destructuring SyntaxErrors retain JSC prose",
        .source =
        \\var rows = [
        \\  ["([a]) = [];", "Left side of assignment is not a reference."],
        \\  ["[...a,] = [];", "Unexpected token ','. Expected a closing ']' following a rest element destructuring pattern."],
        \\  ["[...a, b] = [];", "Unexpected token ','. Expected a closing ']' following a rest element destructuring pattern."],
        \\  ["[(a = 1)] = [];", "Invalid destructuring assignment target."],
        \\  ["({...a, b} = {});", "Unexpected token ','. Cannot parse assignment pattern."],
        \\  ["({...a,} = {});", "Unexpected token ','. Cannot parse assignment pattern."],
        \\  ["({...(a + b)} = {});", "Invalid destructuring assignment target."],
        \\  ["\"use strict\"; ({...eval} = {});", "Unexpected token '}'. Cannot modify 'eval' in strict mode."],
        \\  ["({a: (b = 1)} = {});", "Invalid destructuring assignment target."],
        \\  ["let {...1} = {};", "Unexpected number '1'. Expected a binding element."],
        \\  ["let {+} = {};", "Unexpected token '+'. Expected a property name."],
        \\  ["let {\"x\"} = {};", "Unexpected token '}'. Expected a ':' prior to a named destructuring property."],
        \\  ["let {break} = {};", "Cannot use abbreviated destructuring syntax for keyword 'break'."],
        \\  ["let {...break} = {};", "Cannot use the keyword 'break' as a lexical variable name."],
        \\  ["\"use strict\"; let {...eval} = {};", "Cannot destructure to a variable named 'eval' in strict mode."],
        \\  ["({ get #x() {} });", "Cannot declare a private setter or getter outside a class."],
        \\  ["({ + });", "Unexpected token '+'. Expected a property name."],
        \\  ["({ *foo });", "Unexpected token '}'. Expected a parenthesis for argument list."],
        \\  ["({ async foo });", "Unexpected token '}'. Expected a parenthesis for argument list."],
        \\  ["({ break });", "Cannot use the keyword 'break' as a shorthand property name."],
        \\  ["function* g() { return { yield }; }", "Cannot use 'yield' as a shorthand property name in a generator function."],
        \\  ["async function f() { return { await }; }", "Cannot use 'await' as a shorthand property name in an async function."],
        \\  ["({ \"x\" });", "Unexpected token '}'. Expected an identifier as property name."],
        \\];
        \\rows.reduce(function(bits, row, i) {
        \\  try { eval(row[0]); return bits; }
        \\  catch (error) { return error instanceof SyntaxError && error.message === row[1] ? bits | (1 << i) : bits; }
        \\}, 0)
        ,
        .expected = 8388607,
    },
    .{
        .name = "dynamic import SyntaxErrors retain JSC prose",
        .source =
        \\var rows = [
        \\  ["import.1", "Unexpected number '.1'. import call expects one or two arguments."],
        \\  ["import.meta", "import.meta is only valid inside modules."],
        \\  ["import.\\u006deta", "Unexpected identifier '\\u006deta'. \"import.\" can only be followed with meta."],
        \\  ["import.foo('x')", "Unexpected identifier 'foo'. \"import.\" can only be followed with meta."],
        \\  ["import()", "Unexpected token ')'"],
        \\  ["import(...x)", "Unexpected token '...'"],
        \\  ["import('x', ...y)", "Unexpected token '...'"],
        \\];
        \\rows.reduce(function(bits, row, i) {
        \\  try { eval(row[0]); return bits; }
        \\  catch (error) { return error instanceof SyntaxError && error.message === row[1] ? bits | (1 << i) : bits; }
        \\}, 0)
        ,
        .expected = 127,
    },
    .{
        .name = "malformed template escapes retain JSC prose",
        .source =
        \\var rows = [
        \\  ["`\\x0`", "\\x can only be followed by a hex character sequence"],
        \\  ["`\\u0`", "\\u can only be followed by a Unicode character sequence"],
        \\  ["`\\8`", "The only valid numeric escape in strict mode is '\\0'"],
        \\];
        \\rows.reduce(function(bits, row, i) {
        \\  try { eval(row[0]); return bits; }
        \\  catch (error) { return error instanceof SyntaxError && error.message === row[1] ? bits | (1 << i) : bits; }
        \\}, 0)
        ,
        .expected = 7,
    },
    .{
        // #945/#950: arrows and other function-like boundaries own their label
        // and generator contexts, while arrow parameters still inherit [Yield].
        // A nested label must not overwrite the outer list's retained storage.
        .name = "function boundaries isolate and restore labels yield and strict parameters",
        .source =
        \\var rows = [
        \\  ["var n=0; l: for(var i=0;i<3;i++){ [1].forEach(()=>{ n++; if(i===1) break l; }); } 1", false],
        \\  ["outer: { (() => { break outer; })(); } 1", false],
        \\  ["outer: for(;;){ (() => { continue outer; })(); } 1", false],
        \\  ["outer: { async () => { break outer; }; } 1", false],
        \\  ["function* g(){ () => { yield 1; }; } 1", false],
        \\  ["(eval) => { 'use strict'; }", false],
        \\  ["eval => { 'use strict'; }", false],
        \\  ["async (arguments) => { 'use strict'; }", false],
        \\  ["(yield) => { 'use strict'; }", false],
        \\  ["(interface) => { 'use strict'; }", false],
        \\  ["(let) => { 'use strict'; }", false],
        \\  ["static => { 'use strict'; }", false],
        \\  ["outer: for(;;){ (()=>{ outer: for(;;) break outer; }); break outer; } 1", true],
        \\  ["function* g(){ () => { var yield; }; } 1", true],
        \\  ["function* g(){ () => { yield.x; }; } 1", true],
        \\  ["function* g(){ () => { yield = 1; }; } 1", true],
        \\  ["globalThis['yield']=7; function* g(){ var f=()=>yield; return f(); } g().next().value===7 ? 1 : 0", true],
        \\  ["outer: for(;;){ function f(){ inner:{ break inner; } } break outer; } 1", true],
        \\  ["outer: for(;;){ (()=>{ inner:{ break inner; } }); break outer; } 1", true],
        \\  ["outer: for(;;){ class C { static { inner:{ break inner; } } } break outer; } 1", true],
        \\];
        \\rows.reduce(function(bits, row, i) {
        \\  try { var value = (0, eval)(row[0]); return row[1] && value === 1 ? bits | (1 << i) : bits; }
        \\  catch (e) { return !row[1] && e instanceof SyntaxError ? bits | (1 << i) : bits; }
        \\}, 0)
        ,
        .expected = 1048575,
    },
    .{
        // #930 family 1: what node accepts beside those rejections -- distinct
        // names, duplicate vars, a lexical shadow in a nested block, a var that
        // repeats an outer function's lexical name, sloppy Annex B duplicate
        // block functions (an object literal method is sloppy too), names reused
        // across sibling functions or after them, and a `var` repeating a simple
        // catch parameter (Annex B.3.4). One bit per program.
        .name = "function bodies in expressions accept what node accepts",
        .source =
        \\var programs = [
        \\  "(function(){ let x; var y; })();",
        \\  "var g0 = function (f) {}; g0(function(){ var x; var x; });",
        \\  "({ m(){ let x; { var y; } } });",
        \\  "xx = () => { let y; { let y; } };",
        \\  "function h(){ let x; return function(){ var x; } }",
        \\  "(function(){ { function f(){} function f(){} } })();",
        \\  "(function(){ 'use strict'; { function f(){} } })();",
        \\  "[() => { var z; }, () => { let z; }];",
        \\  "let {a = () => { var z; }} = {}; var z;",
        \\  "(function(){ let x; })(); var x;",
        \\  "({ m(){ { function g(){} function g(){} } } });",
        \\  "(function(){ try {} catch (e) { var e; } })();",
        \\];
        \\programs.reduce(function (bits, source, i) {
        \\  try { (0, eval)(source); return bits | (1 << i); } catch (e) { return bits; }
        \\}, 0)
        ,
        .expected = 4095,
    },
    .{
        // #933 item 8: what node accepts beside those rejections -- a var before or
        // after the loop, a lexical shadow in the body, a `var` head, other names,
        // and a var inside a function, arrow or static block in the body, each
        // its own var scope. One bit per program.
        .name = "lexical for heads accept vars outside their body's var scope",
        .source =
        \\var programs = [
        \\  "var x; for (let x of []) {}",
        \\  "for (let x of []) { function f(){ var x; } }",
        \\  "for (let x of []) { (() => { var x; })(); }",
        \\  "for (let x of []) { class C { static { var x; } } }",
        \\  "for (let x of []) { let y; } var x;",
        \\  "for (let x of []) { let x; }",
        \\  "for (var x of []) { var x; }",
        \\  "for (let x of []) { var y; }",
        \\  "for (let x of []) { for (let y of []) { var z; } var w; }",
        \\  "for (let x of []) { var f = function () { var x; }; }",
        \\];
        \\programs.reduce(function (bits, source, i) {
        \\  try { (0, eval)(source); return bits | (1 << i); } catch (e) { return bits; }
        \\}, 0)
        ,
        .expected = 1023,
    },
    .{
        .name = "operator precedence",
        .source = "1 + 2 * 3",
        .expected = 7,
    },
    .{
        .name = "automatic semicolon insertion",
        .source = "let x = 1\nx + 2",
        .expected = 3,
    },
    .{
        .name = "nested destructuring binding",
        .source = "let { a, b: { c } } = { a: 4, b: { c: 5 } }; a + c",
        .expected = 9,
    },
    .{
        .name = "template interpolation",
        .source = "let x = 3; `v${x}` === 'v3' ? 1 : 0",
        .expected = 1,
    },
    .{
        .name = "template substitutions share the ordinary expression lexer",
        .source =
        \\function tag(strings, value) { return value; }
        \\var bits = 0;
        \\if (`${typeof /}/}` === "object") bits |= 1;
        \\if (`${(() => { return /}/.source })()}` === "}") bits |= 2;
        \\if (`${void /`/}` === "undefined") bits |= 4;
        \\if (`${[1].map(function(){ return /\"/.source })[0]}` === "\\\"") bits |= 8;
        \\if (`${"source" in /}/}` === "true") bits |= 16;
        \\if (`${(function(v){ switch (v) { case /}/.source: return 12 } })("}")}` === "12") bits |= 32;
        \\if (tag`${typeof /}/}` === "object") bits |= 64;
        \\var escaped = `a${"a\"b".split("").map(c => { return /\"/.test(c) ? "&quot;" : c }).join("")}z`;
        \\if (escaped === "aa&quot;bz") bits |= 128;
        \\var i = 1; if (`${i++ / 2}` === "0.5") bits |= 256;
        \\bits
        ,
        .expected = 511,
    },
    .{
        .name = "division and regex remain distinct after updates properties and control heads",
        .source =
        \\var bits = 0;
        \\var i = 1; if (i++ / 2 === 0.5) bits |= 1;
        \\var t = 4; if (t--/2 === 2) bits |= 2;
        \\var x = 10, y = 2; if (x++ /y/ 1 === 5) bits |= 4;
        \\var n = 3; if (n-- / 3 === 1) bits |= 8;
        \\var o = { default: 8 }; if (o.default / 2 === 4) bits |= 16;
        \\var s = { delete: 12, total: 3, in: 9 }; if (s.delete / s.total === 4) bits |= 32; if (s.in / 3 === 3) bits |= 64;
        \\var r = { return: 10 }; if (r.return / 2 === 5) bits |= 128;
        \\var m = { default: 10 }; if (m?.default / 5 === 2) bits |= 256;
        \\var a = 0; if (1) /"/.test("\"") && (a = 1); if (a === 1) bits |= 512;
        \\var b = 0; if (1) /}/.test("}") && (b = 1); if (b === 1) bits |= 1024;
        \\var c = 0, wi = 0; while (wi++ < 1) /}/.test("}") && (c = 1); if (c === 1) bits |= 2048;
        \\var d = 0; for (var fi = 0; fi < 1; fi++) /"/.test("\"") && (d = 1); if (d === 1) bits |= 4096;
        \\function min(a){if(a)/"/.test(a)&&(a=1);return a} if (min("\"") === 1) bits |= 8192;
        \\function* gen(){ yield /a/.source; } if (gen().next().value === "a") bits |= 16384;
        \\async function asyncRegex(){ return await /a/.source; } bits |= 32768;
        \\if (++/a/g.lastIndex === 1) bits |= 65536;
        \\function returned(){ return /a/.source; } if (returned() === "a") bits |= 131072;
        \\var dw = 0; do {} while (0) /x/.test("x") && (dw = 1); if (dw === 1) bits |= 262144;
        \\var w = 0; with ({}) /x/.test("x") && (w = 1); if (w === 1) bits |= 524288;
        \\bits
        ,
        .expected = 1048575,
    },
    .{
        .name = "parser lexical goals distinguish contextual regex and division",
        .source =
        \\var bits = 0;
        \\label: {} /\"/.test("\\\"") && (bits |= 1);
        \\switch (0) { case 0: {} /\"/.test("\\\"") && (bits |= 2); }
        \\var divided = class {} / 2; if (divided !== divided) bits |= 4;
        \\function* generator(){ yield /\"/.source; } if (generator().next().value === "\\\"") bits |= 8;
        \\async function task(){ return await /\"/.source; } bits |= 16;
        \\var arrow = (first = /[)]/, second = class {} / 2) => second; if (arrow() !== arrow()) bits |= 32;
        \\for (var first = /[;]/, value = class {} / 2; value; value--) {} bits |= 64;
        \\if ((class {} / 2) !== (class {} / 2)) bits |= 128;
        \\var nested = (first = `${`)`}`, second = class {} / 2) => second; if (nested() !== nested()) bits |= 256;
        \\bits
        ,
        .expected = 511,
    },
    .{
        .name = "class private field",
        .source = "class C { #x = 7; get() { return this.#x; } } new C().get()",
        .expected = 7,
    },
    .{
        .name = "base class instance initialization",
        .source = "let outer = 3; let key = Symbol('field'); class C { value = outer; [key]; #private = 4; accessor auto = 5; constructor(outer = this.value + 3) { this.argument = outer; } score() { return this.value + this.#private + this.auto + this.argument + (Object.prototype.hasOwnProperty.call(this, key) ? 1 : 0); } } new C().score()",
        .expected = 19,
    },
    .{
        .name = "derived constructor activation",
        .source = "class Base { constructor(value) { this.base = value; } } class Derived extends Base { field = 3; #private = 4; constructor(value) { super(value + 1); } score() { return this.base + this.field + this.#private; } } new Derived(8).score()",
        .expected = 16,
    },
    .{
        .name = "optional chain with nullish fallback",
        .source = "let o = null; (o?.x ?? 41) + 1",
        .expected = 42,
    },
    .{
        .name = "regexp literal",
        .source = "/a+/.test('aaa') ? 1 : 0",
        .expected = 1,
    },
    .{
        .name = "for-in head forms",
        .source = "let score = 0; for (const key in { a: 1, b: 2 }) score += key === 'a' ? 1 : 2; for (const [first] in { cd: 1 }) score += first === 'c' ? 4 : 0; score",
        .expected = 7,
    },
    .{
        .name = "sloppy mapped arguments frame aliases",
        .source =
        \\function mapped(a, a, b) {
        \\  var score = a === 2 ? 1 : 0;
        \\  arguments[1] = 5; score += a === 5 ? 2 : 0;
        \\  a = 7; score += arguments[1] === 7 ? 4 : 0;
        \\  delete arguments[1]; a = 9;
        \\  score += arguments[1] === undefined && a === 9 ? 8 : 0;
        \\  b = 11; score += arguments.length === 2 && b === 11 ? 16 : 0;
        \\  return score;
        \\}
        \\mapped(1, 2)
        ,
        .expected = 31,
    },
    .{
        .name = "named rest parameter frame",
        .source = "function rest(head, ...tail) { return head + tail.length + tail[0]; } rest(3, 4, 5)",
        .expected = 9,
    },
    .{
        .name = "destructuring parameter frame",
        .source = "function pick([first, { value }, ...tail], { keep, ...rest }) { return first + value + tail.length + keep + rest.extra; } pick([1, { value: 2 }, 3, 4], { keep: 5, extra: 6 })",
        .expected = 16,
    },
    .{
        .name = "primitive literal default parameter frame",
        .source = "function defaults(number = 4, text = 'four', flag = false, [letter] = 'z') { return number + text.length + (flag ? 100 : 0) + letter.length; } defaults(undefined, undefined, undefined, undefined)",
        .expected = 9,
    },
    .{
        .name = "closed primitive default expression frame",
        .source = "function defaults(signed = -1, sum = 1 + 2, logical = (false && (1n / 0n)) || 4, choice = false ? (1n / 0n) : 6, sequence = (7, 8), voided = void 0, shifted = 8 >> 1, comparison = 1 < 2, bitwise = 6 & 3) { return signed + sum + logical + choice + sequence + (voided === undefined) + shifted + comparison + bitwise; } defaults()",
        .expected = 28,
    },
    .{
        .name = "invocation context default leaves",
        .source = "function defaults(receiver = this, target = new.target, args = arguments) { return (receiver === globalThis ? 1 : 0) + (target === undefined ? 2 : 0) + args.length; } function Box(target = new.target) { this.score = target === Box ? 10 : 0; } defaults(undefined, undefined, undefined, 7) + (new Box()).score",
        .expected = 17,
    },
    .{
        .name = "earlier parameter default references",
        .source = "function defaults(first, second = first, [third], fourth = third, arguments, fifth = arguments) { return second + fourth + fifth; } defaults(2, undefined, [3], undefined, 4)",
        .expected = 9,
    },
    .{
        .name = "parameter safe default expression trees",
        .source = "function defaults(first, sum = first + 2, neg = -first, logical = first && 3, choice = first ? 4 : 5, sequence = (first, 6)) { return sum + neg + logical + choice + sequence; } defaults(2)",
        .expected = 15,
    },
    .{
        .name = "parameter local property defaults",
        .source = "function reads(first, key, named = first.value, computed = first[key], nested = first.child.value) { return named + computed + nested; } reads({ value: 3, child: { value: 4 } }, 'value')",
        .expected = 10,
    },
    .{
        .name = "parameter local call defaults",
        .source = "function calls(callee, receiver, direct = callee(2), method = receiver.add(3)) { return direct + method; } calls(function (value) { return value + 1; }, { base: 4, add(value) { return this.base + value; } })",
        .expected = 10,
    },
    .{
        .name = "parameter local construction defaults",
        .source = "function Box(value) { this.value = value; } function constructs(Ctor, direct = new Ctor(3), nested = new Ctor(direct.value + 1)) { return direct.value + nested.value; } constructs(Box)",
        .expected = 7,
    },
};

const frontend_error_cases = [_]ErrorCase{
    // #930 family 1: every function body is checked once as it is parsed,
    // so its lexical/var conflicts are found wherever the function appears.
    .{
        .name = "lexical/var conflict in a function in an immediately invoked function",
        .source = "(function(){ let x; var x; })();",
    },
    .{
        .name = "lexical/var conflict in a function in a call argument",
        .source = "g0(function(){ let x; var x; });",
    },
    .{
        .name = "lexical/var conflict in a function in an object literal method",
        .source = "({ m(){ let x; var x; } });",
    },
    .{
        .name = "lexical/var conflict in a function in an assigned arrow",
        .source = "xx = () => { let y; var y; };",
    },
    .{
        .name = "lexical/var conflict in a function in a returned function",
        .source = "function h(){ return function(){ let x; var x; } }",
    },
    .{
        .name = "lexical/var conflict in a function in a later declarator",
        .source = "var a = 1, b = function(){ let x; var x; };",
    },
    .{
        .name = "lexical/var conflict in a function in a class method in a later declarator",
        .source = "let a2 = 1, b2 = class { m(){ let x; var x; } };",
    },
    .{
        .name = "lexical/var conflict in a function in a for-head initializer",
        .source = "for (var i = function(){ let x; var x; };;) break;",
    },
    .{
        .name = "lexical/var conflict in a function in an array literal",
        .source = "[function(){ let z; var z; }];",
    },
    .{
        .name = "lexical/var conflict in a function in a class field initializer",
        .source = "class K { x = function(){ let z; var z; }; }",
    },
    .{
        .name = "lexical/var conflict in a function in a destructuring default",
        .source = "let {a = function(){ let z; var z; }} = {};",
    },
    .{
        .name = "lexical/var conflict in a function in a new expression",
        .source = "new function(){ let x; var x; };",
    },
    .{
        .name = "lexical/var conflict in a function in a parameter default",
        .source = "function f2(a = function(){ let x; var x; }){}",
    },
    .{
        .name = "lexical/var conflict in a function in a template substitution",
        .source = "`${function(){ let x; var x; }}`;",
    },
    .{
        .name = "lexical/var conflict in a function in an object literal getter",
        .source = "({ get p(){ let x; var x; } });",
    },
    .{
        .name = "lexical/var conflict in a function in an async arrow",
        .source = "async () => { let x; var x; };",
    },
    // The other declaration checks the per-body walk runs reach the same
    // positions: a `var` against a destructured catch parameter (#931), a
    // `with` body (family 2), and strict duplicate block functions under the
    // body's own strictness (family 4).
    .{
        .name = "var repeating a destructured catch parameter in an immediately invoked function",
        .source = "(function(){ try {} catch ([e]) { var e; } })();",
    },
    .{
        .name = "var repeating a destructured catch parameter in an arrow in an array literal",
        .source = "[() => { try {} catch ([e]) { var e; } }];",
    },
    .{
        .name = "lexical/var conflict in a with body in an immediately invoked function",
        .source = "(function(){ with ({}) { let q; var q; } })();",
    },
    .{
        .name = "strict duplicate block functions in an immediately invoked function",
        .source = "(function(){ \"use strict\"; { function g(){} function g(){} } })();",
    },
    .{
        .name = "strict duplicate switch functions in a class method in an assignment",
        .source = "x = class { m(){ switch (0) { case 0: function g(){} case 1: function g(){} } } };",
    },
    // #933 item 8: a lexical `for` head's names must not be var-declared in its
    // body (14.7.4.1, 14.7.5.1). Checked once per head by declaration order
    // instead of re-collecting the body at every nested head.
    .{
        .name = "a lexical for-of head collides with a var in its body",
        .source = "for (let x of []) { var x; }",
    },
    .{
        .name = "a lexical for-of head collides with a var statement body",
        .source = "for (let x of []) var x;",
    },
    .{
        .name = "a destructured lexical head collides with a var in a nested block",
        .source = "for (let [x] of []) { { var x; } }",
    },
    .{
        .name = "a classic lexical head collides with a var in its body",
        .source = "for (let x = 0; false;) { var x; }",
    },
    .{
        .name = "a const for-in head collides with a var under an if",
        .source = "for (const x in {}) { if (1) var x; }",
    },
    .{
        .name = "an outer lexical head collides with a var in a nested for body",
        .source = "for (let x of []) for (let y of []) { var x; }",
    },
    .{
        .name = "a lexical head collides with a var for-of target in its body",
        .source = "for (let x of []) { for (var x of []) {} }",
    },
    .{
        .name = "a lexical head collides with a destructured var in its body",
        .source = "for (let x of []) { var {x} = {}; }",
    },
    .{
        .name = "a second classic head binding collides with a var in finally",
        .source = "for (let x = 0, y = 0; false;) { try {} finally { var y; } }",
    },
    .{
        .name = "duplicate lexical binding rejected",
        .source = "let x; let x;",
    },
    .{
        .name = "top-level new target rejected",
        .source = "new.target",
    },
    .{
        .name = "parenthesized destructuring target rejected",
        .source = "({ a }) = { a: 1 };",
    },
    .{
        .name = "undeclared private name rejected",
        .source = "class C { #x; read(o) { return o.#missing; } }",
    },
    .{
        .name = "malformed for-of head rejected",
        .source = "for (let x = 0 of []) {}",
    },
};

const vm_cases = [_]Case{
    .{
        .name = "numeric loop",
        .source = "let s = 0; for (let i = 0; i < 1000; i++) s += i % 17; s",
        .expected = 7979,
    },
    .{
        .name = "packed array loop",
        .source = "let a = [1, 2, 3, 4]; let s = 0; for (let i = 0; i < 2000; i++) s += a[i & 3]; s",
        .expected = 5000,
    },
    .{
        .name = "property loop",
        .source = "let o = { x: 1, y: 2 }; let s = 0; for (let i = 0; i < 1000; i++) { o.x++; s += o.y; } o.x + s",
        .expected = 3001,
    },
    .{
        .name = "recursive calls",
        .source = "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); } fib(12)",
        .expected = 144,
    },
};

const jit_cases = [_]Case{
    .{
        .name = "guarded remainder loop",
        .source = "function f(n) { let s = 0; for (let i = 0; i < n; i++) s += i % 17; return s; } f(1000)",
        .expected = 7979,
    },
    .{
        .name = "fractional guard fallback",
        .source = "function f(n) { let x = 0; for (let i = 0; i < n; i++) x++; return x; } f(1000) + f(2.5)",
        .expected = 1003,
    },
    .{
        .name = "constant function tier",
        .source = "function c() { return 42; } let s = 0; for (let i = 0; i < 1000; i++) s += c(); s",
        .expected = 42000,
    },
};

const runtime_cases = [_]Case{
    .{
        // #933 item 8b: every `(` that starts an AssignmentExpression asked
        // whether its matching `)` is followed by `=>`, each by scanning to the
        // match, so N nested groups rescanned the rest of the group N times.
        // Past 64 levels the parser now indexes every paren once; these groups
        // are 100 deep so the index answers, and each must mean what the scan
        // said it meant.
        .name = "deeply nested parentheses keep their arrow and call meaning",
        .source =
        \\function nest(n, core) { return "(".repeat(n) + core + ")".repeat(n); }
        \\var checks = [];
        \\// An arrow at the bottom of a deep group is still an arrow.
        \\checks.push((0, eval)(nest(100, "(x) => x * 2"))(21) === 42);
        \\// An arrow head whose default nests the groups is still an arrow head.
        \\checks.push((0, eval)("(a = " + nest(100, "7") + ") => a")() === 7);
        \\checks.push(typeof (0, eval)("async (a = " + nest(100, "7") + ") => a") === "function");
        \\// A deep argument list is a call, and plain grouping is grouping.
        \\checks.push((0, eval)("var id = function (v) { return v; }; id(" + nest(100, "5") + ")") === 5);
        \\checks.push((0, eval)(nest(100, "3")) === 3);
        \\// A group followed by an arrow in the same sequence.
        \\checks.push((0, eval)(nest(100, "1") + ", ((y) => y + 1)(4)") === 5);
        \\// `async (…)` with a deep argument is a call to a function named async.
        \\checks.push((0, eval)("var async = function (v) { return v; }; async(" + nest(100, "9") + ")") === 9);
        \\// One bit per check, so a failure names the shape that regressed.
        \\checks.reduce(function (bits, ok, i) { return ok ? bits | (1 << i) : bits; }, 0)
        ,
        .expected = 127,
    },
    .{
        // #936: source nested deeper than the stack allows segfaulted the
        // process during lexing or parsing. It must instead raise the same
        // catchable RangeError as runaway recursion -- JavaScriptCore reports
        // deeply nested source exactly this way, message included -- while an
        // ordinary depth still runs and a real syntax error stays a SyntaxError.
        .name = "deeply nested source raises a catchable RangeError",
        .source =
        \\function nest(open, core, close, n) { return open.repeat(n) + core + close.repeat(n); }
        \\function exhausted(run) {
        \\  try { run(); return false; }
        \\  catch (e) { return e instanceof RangeError && e.message === "Maximum call stack size exceeded."; }
        \\}
        \\var n = 200000;
        \\var parens = exhausted(function () { (0, eval)(nest("(", "1", ")", n)); });
        \\var arrays = exhausted(function () { (0, eval)(nest("[", "1", "]", n)); });
        \\// eval returns early for source made only of empty blocks, so give the innermost block a statement.
        \\var blocks = exhausted(function () { (0, eval)(nest("{", "0;", "}", n)); });
        \\var unary = exhausted(function () { (0, eval)("!".repeat(n) + "1"); });
        \\var templates = exhausted(function () { (0, eval)(nest("`${", "1", "}`", n)); });
        \\var constructed = exhausted(function () { Function(nest("(", "1", ")", n)); });
        \\var forAwaitHead = exhausted(function () { (0, eval)("async function f() { for await (a[" + nest("(", "1", ")", n) + "] of []); }"); });
        \\var generatorParams = exhausted(function () { Object.getPrototypeOf(function* () {}).constructor("a = " + nest("`${", "1", "}`", n), ""); });
        \\var asyncGeneratorParams = exhausted(function () { Object.getPrototypeOf(async function* () {}).constructor("a = " + nest("`${", "1", "}`", n), ""); });
        \\var shallow = (0, eval)(nest("(", "7", ")", 300)) === 7 && (0, eval)(nest("`${", "7", "}`", 300)) === "7";
        \\var syntax = (function () { try { (0, eval)("(("); return false; } catch (e) { return e instanceof SyntaxError; } })();
        \\// One bit per check, so a failure names the shape that regressed.
        \\[parens, arrays, blocks, unary, templates, constructed, forAwaitHead, generatorParams, asyncGeneratorParams, shallow, syntax].reduce(function (bits, ok, i) { return ok ? bits | (1 << i) : bits; }, 0)
        ,
        .expected = 2047,
    },
    .{
        // #937: creating a generator compiles its body, nested function bodies
        // included. Each shape sweeps depths until the parser gives up. Every
        // depth must either work or throw the RangeError -- never crash -- and
        // for shapes the parser walks more cheaply than the compiler there must
        // be a depth that parses (inside an unexecuted block) but throws when
        // the function is created. That pins the compiler's exhaustion as a
        // RangeError: had it fallen back to a rejection, creation would succeed.
        .name = "deeply nested function bodies raise RangeError when compiled",
        .source =
        \\function outcome(run) {
        \\  try { run(); return 1; }
        \\  catch (e) { return e instanceof RangeError && e.message === "Maximum call stack size exceeded." ? 2 : 0; }
        \\}
        \\var shapes = [
        \\  [false, function (n) { return "{".repeat(n) + "x = 1;" + "}".repeat(n); }],
        \\  [true, function (n) { return "var a; " + "a = ".repeat(n) + "1;"; }],
        \\  [true, function (n) { return "!".repeat(n) + "1;"; }],
        \\  [true, function (n) { return "var o = {}; o" + ".b".repeat(n) + ";"; }],
        \\  [true, function (n) { return "var " + "[".repeat(n) + "z" + "]".repeat(n) + " = [];"; }],
        \\  [false, function (n) { return "try {} catch ([a]) {".repeat(n) + "}".repeat(n); }],
        \\  [false, function (n) { return "var c; " + "c ? ".repeat(n) + "1" + " : 2".repeat(n) + ";"; }],
        \\];
        \\var wrappers = [
        \\  function (body) { return "function* g() { " + body + " }"; },
        \\  function (body) { return "function* g() { (function () { " + body + " }); }"; },
        \\  function (body) { return "function* g() { (function () { for (;;) { " + body + " break; } }); }"; },
        \\];
        \\// One bit per shape and wrapper, so a failure names the combination.
        \\var passed = 0;
        \\shapes.forEach(function (entry, s) {
        \\  wrappers.forEach(function (wrap, w) {
        \\    var ok = true, band = false, lo = 0, hi = 0;
        \\    for (var n = 250; n <= 128000; n *= 2) {
        \\      var source = wrap(entry[1](n));
        \\      var parsed = outcome(function () { (0, eval)("if (false) { " + source + " }"); });
        \\      var created = outcome(function () { (0, eval)(source); });
        \\      if (parsed === 0 || created === 0 || (n === 250 && created !== 1)) ok = false;
        \\      if (parsed === 1 && created === 2) band = true;
        \\      if (parsed === 2) { hi = n; break; }
        \\      lo = n;
        \\    }
        \\    // The parser's and compiler's limits can fall within one doubling;
        \\    // find the deepest source that parses and require creating it to throw.
        \\    if (entry[0] && !band && lo && hi) {
        \\      while (hi - lo > 1) {
        \\        var mid = (lo + hi) >> 1;
        \\        if (outcome(function () { (0, eval)("if (false) { " + wrap(entry[1](mid)) + " }"); }) === 1) lo = mid; else hi = mid;
        \\      }
        \\      band = outcome(function () { (0, eval)(wrap(entry[1](lo))); }) === 2;
        \\    }
        \\    if (ok && (band || !entry[0])) passed |= 1 << (s * wrappers.length + w);
        \\  });
        \\});
        \\passed
        ,
        .expected = 2097151,
    },
    .{
        // #938: the tree-walker recursed over statements, expressions, patterns,
        // hoisting and class member copies within a single call, where
        // stackGuard does not look, and crashed on source the parser accepts.
        // Every depth up to the parser's limit must evaluate or throw the
        // RangeError, never crash; a shallow copy of each shape must still work.
        .name = "deeply nested source evaluates or raises RangeError in the tree-walker",
        .source =
        \\function outcome(run) {
        \\  try { run(); return 1; }
        \\  catch (e) { return e instanceof RangeError && e.message === "Maximum call stack size exceeded." ? 2 : 0; }
        \\}
        \\// Evaluated by indirect eval, which the tree-walker runs. One bit per shape.
        \\var shapes = [
        \\  function (n) { return "'use strict'; var x; " + "{".repeat(n) + "x = 1;" + "}".repeat(n); },
        \\  function (n) { return "var x; " + "if (1) ".repeat(n) + "x = 1;"; },
        \\  function (n) { var s = "var x; "; for (var i = 0; i < n; i++) s += "l" + i + ": "; return s + "x = 1;"; },
        \\  function (n) { return "var x; " + "with ({}) ".repeat(n) + "x = 1;"; },
        \\  function (n) { return "var a = {}; a.b = a; a" + ".b".repeat(n) + ";"; },
        \\  function (n) { return "var a; " + "a = ".repeat(n) + "1;"; },
        \\  function (n) { return "!".repeat(n) + "1;"; },
        \\  function (n) { return "var c = 1; " + "c ? ".repeat(n) + "1" + " : 2".repeat(n) + ";"; },
        \\  function (n) { return "`${".repeat(n) + "1" + "}`".repeat(n) + ";"; },
        \\  function (n) { return "var o = " + "[".repeat(n) + "1" + "]".repeat(n) + "; var " + "[".repeat(n) + "z" + "]".repeat(n) + " = o;"; },
        \\  function (n) { return "(class { #x = 1; m() { " + "{".repeat(n) + "this.#x;" + "}".repeat(n) + " } });"; },
        \\];
        \\var bits = 0;
        \\shapes.forEach(function (shape, i) {
        \\  var ok = outcome(function () { (0, eval)(shape(50)); }) === 1;
        \\  for (var n = 250; n <= 64000 && ok; n *= 2) {
        \\    var parsed = outcome(function () { (0, eval)("function __never() { " + shape(n) + " }"); });
        \\    var evaluated = outcome(function () { (0, eval)(shape(n)); });
        \\    if (parsed === 0 || evaluated === 0) ok = false;
        \\    // Deeper sources add nothing once either limit is reached, and every
        \\    // evaluated tree stays in the context's arena.
        \\    if (parsed === 2 || evaluated === 2) break;
        \\  }
        \\  if (ok) bits |= 1 << i;
        \\});
        \\bits
        ,
        .expected = 2047,
    },
    .{
        // #940: a deep chain built at *runtime* -- nested arrays, trap-less
        // proxies, bound functions -- is walked under one native built-in call,
        // so `stackGuard`'s call-depth counter never moves and the recursion
        // ran off the stack. Where a link can run user code (flat reads
        // elements) the answer is the RangeError; where nothing between links
        // is observable (bound [[Call]]/[[Construct]], IsArray) the chain is
        // walked and the operation answers, as it does in other engines.
        .name = "deep runtime chains answer or raise RangeError instead of crashing",
        .source =
        \\function outcome(run) {
        \\  try { return run(); }
        \\  catch (e) { return e instanceof RangeError && e.message === "Maximum call stack size exceeded." ? "range" : "other: " + e; }
        \\}
        \\function chainProxy(base, n) { var p = base; for (var i = 0; i < n; i++) p = new Proxy(p, {}); return p; }
        \\// A bound function's name is "bound " + the target's, so a chain of them
        \\// stores a quadratic amount of text (#942). Reset the configurable name
        \\// each link: this case is about the frames, not the names.
        \\function chainBound(f, n) { for (var i = 0; i < n; i++) { f = f.bind(null); Object.defineProperty(f, "name", { value: "" }); } return f; }
        \\function nestArray(n) { var root = [], cur = root; for (var i = 0; i < n; i++) { var inner = []; cur.push(inner); cur = inner; } cur.push(1); return root; }
        \\var checks = [];
        \\// flat: `depth` is a Number, so `Infinity - 1` never ends a cycle.
        \\var self_ref = [1]; self_ref.push(self_ref);
        \\checks.push(outcome(function () { return self_ref.flat(Infinity).length; }) === "range");
        \\checks.push(outcome(function () { return nestArray(100000).flat(Infinity).length; }) === "range");
        \\checks.push(nestArray(50).flat(Infinity).length === 1);
        \\// Trap-less proxy links forward without a JS call between them.
        \\var deep_proxy = chainProxy({}, 150000);
        \\checks.push(outcome(function () { return Object.getPrototypeOf(deep_proxy); }) === "range");
        \\checks.push(outcome(function () { return Object.isExtensible(deep_proxy); }) === "range");
        \\checks.push(outcome(function () { return Object.defineProperty(deep_proxy, "x", { value: 1 }); }) === "range");
        \\checks.push(outcome(function () { return Object.prototype.toString.call(chainProxy([], 150000)); }) === "range");
        \\// A shallow chain still forwards, and IsArray still sees through it.
        \\checks.push(Object.getPrototypeOf(chainProxy({}, 5)) === Object.prototype);
        \\checks.push(Object.prototype.toString.call(chainProxy([], 5)) === "[object Array]");
        \\// Bound chains are walked, so they answer at any length.
        \\checks.push(outcome(function () { return chainBound(function () { return 7; }, 80000)(); }) === 7);
        \\function Ctor() { this.v = 5; this.nt = new.target; }
        \\var deep_ctor = chainBound(Ctor, 80000);
        \\checks.push(outcome(function () { return new deep_ctor().v; }) === 5);
        \\checks.push(outcome(function () { return ({}) instanceof chainBound(function () {}, 80000); }) === false);
        \\// The walk preserves bound argument order, the innermost bound `this`,
        \\// and step 4 of [[Construct]] in both directions.
        \\function rec(a, b, c) { return [this.tag, a, b, c].join(","); }
        \\checks.push(rec.bind({ tag: "t" }, 1).bind({ tag: "ignored" }, 2)(3) === "t,1,2,3");
        \\var b2 = Ctor.bind(null).bind(null);
        \\checks.push(new b2().nt === Ctor);
        \\function Other() {}
        \\checks.push(Reflect.construct(b2, [], Other).nt === Other);
        \\// One bit per check, so a failure names the shape that regressed.
        \\checks.reduce(function (bits, ok, i) { return ok ? bits | (1 << i) : bits; }, 0)
        ,
        .expected = 32767,
    },
    .{
        // #941: ECMA-262's Array.prototype.join defines no cycle detection, so a
        // self-referential array recursed until the stack guard threw, where
        // JavaScriptCore and V8 render a re-entered receiver as the empty
        // string. Every expected string below was taken from the JavaScriptCore
        // oracle (home-tool); node agrees on all of them except the separator
        // count, where JSC checks the cycle before coercing and V8 after.
        .name = "cyclic arrays join as the empty string instead of throwing",
        .source =
        \\var checks = [];
        \\var a = [1]; a.push(a);
        \\checks.push(String(a) === "1,");
        \\var b = [1, [2]]; b[1].push(b);
        \\checks.push(b.join("-") === "1-2,");
        \\var o = { toString: function () { return "O"; } };
        \\var c = [o]; c.push(c);
        \\checks.push(c.toLocaleString() === "O,");
        \\// The re-entered call returns before coercing its separator again.
        \\var calls = 0;
        \\var sep = { toString: function () { calls++; return "-"; } };
        \\var d = [1];
        \\d.push({ toString: function () { return d.join(sep); } });
        \\checks.push(d.join(sep) === "1-" && calls === 1);
        \\// The receiver leaves the set on a throw from a user toString, so the
        \\// next join of the same array is not silently empty.
        \\var bad = { toString: function () { throw new Error("boom"); } };
        \\var f = [bad]; f.push(f);
        \\var threw = false;
        \\try { f.join(); } catch (e) { threw = e.message === "boom"; }
        \\checks.push(threw);
        \\f[0] = 1;
        \\checks.push(f.join() === "1,");
        \\// The same array twice in one join is not a cycle: it renders twice.
        \\var sib = [1, 2];
        \\checks.push([sib, sib].join("|") === "1,2|1,2");
        \\// A cycle that re-enters through a plain object's toString.
        \\var g = [1]; g.push({ toString: function () { return g.join(); } });
        \\checks.push(g.join() === "1,");
        \\// A two-array cycle renders the inner array as empty.
        \\var i2 = [1]; var j2 = [i2]; i2.push(j2);
        \\checks.push(String(i2) === "1,");
        \\// Deep but acyclic nesting still renders in full.
        \\var deep = []; var cur = deep;
        \\for (var k = 0; k < 40; k++) { var n = [k]; cur.push(n); cur = n; }
        \\checks.push(deep.join(",").length === 109);
        \\// One bit per check, so a failure names the shape that regressed.
        \\checks.reduce(function (bits, ok, i) { return ok ? bits | (1 << i) : bits; }, 0)
        ,
        .expected = 1023,
    },
    .{
        // #939: a classic `for` head was first parsed as a for-in/of target and
        // re-parsed after the rewind, so every function body in the head was
        // parsed twice -- and a `for` nested inside one of those bodies repeated
        // that at its own level, doubling time and arena memory per level
        // (depth 18 cost 411 MB, depth 22 exhausted 3 GB). At depth 24 below,
        // the old parser would need tens of gigabytes; with one parse per head
        // it is instant, so a regression shows up as the process dying rather
        // than as a wrong answer.
        .name = "nested classic for heads parse once per level",
        .source =
        \\function nest(wrap, n) { var s = ";"; for (var i = 0; i < n; i++) s = wrap(s); return s; }
        \\function parses(src) {
        \\  try { (0, eval)("function __never() { " + src + " }"); return true; } catch (e) { return false; }
        \\}
        \\var checks = [];
        \\// The two shapes that grew fastest: a member head and a lexical pattern head.
        \\checks.push(parses(nest(function (s) { return "for (a[function(){ " + s + " }()]; 0;);"; }, 24)));
        \\checks.push(parses(nest(function (s) { return "for (let [a = function(){ " + s + " }] = []; 0;);"; }, 24)));
        \\// Deciding the head form must not change what any head means.
        \\var keys = []; for (var k in { a: 1, b: 2 }) keys.push(k);
        \\checks.push(keys.join() === "a,b");
        \\var sum = 0; for (var v of [1, 2, 3]) sum += v;
        \\checks.push(sum === 6);
        \\var count = 0; for (var i = 0; i < 3; i++) count += i;
        \\checks.push(count === 3);
        \\// A member expression as a for-in target, which is an iteration head
        \\// whose target is not a declaration.
        \\var o = {}; for (o.x in { y: 1 });
        \\checks.push(o.x === "y");
        \\var p, q; for ([p, q] of [[1, 2]]);
        \\checks.push(p === 1 && q === 2);
        \\var last; for (last of [7]);
        \\checks.push(last === 7);
        \\// A classic head whose initializer is a function expression, and the
        \\// `async of =>` head, which is a classic `for` and not a for-of.
        \\var ran = 0; for (var f = function () { return 5; }; f; f = null) ran = f();
        \\checks.push(ran === 5);
        \\checks.push(parses("for (async of => 1; false;);"));
        \\// One bit per check, so a failure names the shape that regressed.
        \\checks.reduce(function (bits, ok, i) { return ok ? bits | (1 << i) : bits; }, 0)
        ,
        .expected = 1023,
    },
    .{
        // #935: the parser builds left-associative chains in a loop, and a
        // template literal desugars to two links per substitution, so a flat
        // source hands evaluation a spine as long as its operand count. Every
        // chain below overflowed the native stack before evaluation walked
        // spines iteratively; other engines run them. Each is evaluated with
        // and without a `let` declaration, which changes how the script is
        // admitted to bytecode, and both results must agree.
        .name = "long flat expression chains evaluate in order",
        .source =
        \\function chain(op, term, n) { var parts = []; for (var i = 0; i < n; i++) parts.push(term); return parts.join(op); }
        \\function both(src) {
        \\  var plain = (0, eval)(src);
        \\  var lexical = (0, eval)("let chainPolicyProbe = 0; " + src);
        \\  return Object.is(plain, lexical) ? plain : "tiers disagree";
        \\}
        \\var n = 20000;
        \\var sum = both(chain("+", "1", n)) === n;
        \\var text = both("(" + chain("+", "'a'", n) + ").length") === n;
        \\var template = both("`" + "${1}".repeat(10000) + "`.length") === 10000;
        \\var conj = both(chain("&&", "1", n)) === 1;
        \\var disj = both(chain("||", "0", n)) === 0;
        \\var coalesce = both(chain("??", "null", n)) === null;
        \\var comma = both("(" + chain(",", "7", n) + ")") === 7;
        \\var compare = both(chain("<", "1", n)) === false; // 1<1 is false, false<1 is true: alternates, n-1 odd
        \\var trace = [];
        \\function t(v) { trace.push(v); return v; }
        \\trace = []; var order = both("t(1) + t(2) - t(3) * t(4) + t(5)") === 1 + 2 - 12 + 5 && trace.join() === "1,2,3,4,5,1,2,3,4,5";
        \\trace = []; var shortAnd = both("t(1) && t(0) && t(3)") === 0 && trace.join() === "1,0,1,0";
        \\trace = []; var shortOr = both("t(0) || t(2) || t(3)") === 2 && trace.join() === "0,2,0,2";
        \\trace = []; var shortNull = both("t(null) ?? t(5) ?? t(6)") === 5 && trace.join() === ",5,,5";
        \\trace = []; var sequence = both("(t(1), t(2), t(3))") === 3 && trace.join() === "1,2,3,1,2,3";
        \\var brand = both("class P { #x; static has(o) { return #x in o && #x in o && true; } } P.has(new P())") === true;
        \\sum && text && template && conj && disj && coalesce && comma && compare && order && shortAnd && shortOr && shortNull && sequence && brand ? 1 : 0
        ,
        .expected = 1,
    },
    .{
        .name = "UTF-16 string search predicates BMP positions",
        .source =
        \\let bmp = "éa";
        \\let ok = bmp.includes("a", 1) && bmp.startsWith("a", 1) && bmp.endsWith("é", 1);
        \\ok = ok && bmp.includes("", bmp.length) && bmp.startsWith("", Infinity) && bmp.endsWith("", -Infinity);
        \\ok ? 1 : 0
        ,
        .expected = 1,
    },
    .{
        .name = "UTF-16 string search predicates astral halves",
        .source =
        \\let astral = "💩a";
        \\(astral.includes("\uD83D") ? 1 : 0) +
        \\(astral.includes("\uDCA9") ? 2 : 0) +
        \\(astral.includes("a", 1) ? 4 : 0) +
        \\(astral.startsWith("\uDCA9", 1) ? 8 : 0) +
        \\(!astral.startsWith("a", 1) ? 16 : 0) +
        \\(astral.endsWith("\uD83D", 1) ? 32 : 0) +
        \\(astral.endsWith("\uDCA9", 2) ? 64 : 0) +
        \\(astral.endsWith("a", 3) ? 128 : 0)
        ,
        .expected = 255,
    },
    .{
        .name = "UTF-16 string search predicates lone surrogates",
        .source =
        \\let lone = "\uD83Dx\uDCA9";
        \\lone.startsWith("\uD83D") && lone.includes("x\uDCA9", 1) && lone.endsWith("\uDCA9") && !lone.includes("💩") ? 1 : 0
        ,
        .expected = 1,
    },
    .{
        .name = "UTF-16 string search predicates coercion order",
        .source =
        \\let order = "";
        \\let search = { toString() { order += "s"; return "a"; } };
        \\let position = { valueOf() { order += "p"; return 1; } };
        \\"ba".includes(search, position) && order === "sp" ? 1 : 0
        ,
        .expected = 1,
    },
    .{
        .name = "UTF-16 string search predicates linear pattern",
        .source =
        \\let prefix = "a".repeat(2048);
        \\(prefix + prefix + "b").includes(prefix + "b") ? 1 : 0
        ,
        .expected = 1,
    },
    .{
        .name = "UTF-16 String index search astral limits",
        .source =
        \\let astral = "💩x💩";
        \\(astral.indexOf("\uD83D") === 0 ? 1 : 0) +
        \\(astral.indexOf("\uDCA9") === 1 ? 2 : 0) +
        \\(astral.indexOf("\uD83D", 1) === 3 ? 4 : 0) +
        \\(astral.indexOf("\uDCA9", 2) === 4 ? 8 : 0) +
        \\(astral.lastIndexOf("\uD83D") === 3 ? 16 : 0) +
        \\(astral.lastIndexOf("\uDCA9") === 4 ? 32 : 0) +
        \\(astral.lastIndexOf("\uDCA9", 3) === 1 ? 64 : 0) +
        \\(astral.lastIndexOf("\uD83D", 2) === 0 ? 128 : 0)
        ,
        .expected = 255,
    },
    .{
        .name = "UTF-16 String index search empty and coercion",
        .source =
        \\let astral = "💩";
        \\let order = "";
        \\let search = { toString() { order += "s"; return "a"; } };
        \\let position = { valueOf() { order += "p"; return 1; } };
        \\let ok = astral.indexOf("", 1) === 1 && astral.indexOf("", Infinity) === 2;
        \\ok = ok && astral.lastIndexOf("") === 2 && astral.lastIndexOf("", 1) === 1;
        \\ok = ok && "ba".indexOf(search, position) === 1 && order === "sp";
        \\order = "";
        \\ok = ok && "ba".lastIndexOf(search, position) === 1 && order === "sp";
        \\ok ? 1 : 0
        ,
        .expected = 1,
    },
    .{
        .name = "UTF-16 String index search linear overlap",
        .source =
        \\let prefix = "a".repeat(2048);
        \\let text = prefix + prefix + "b";
        \\text.indexOf(prefix + "b") === 2048 && text.lastIndexOf(prefix + "b") === 2048 &&
        \\text.lastIndexOf(prefix, 2047) === 2047 && "aaaaa".lastIndexOf("aaa") === 2 ? 1 : 0
        ,
        .expected = 1,
    },
    .{
        .name = "JSON hostile nesting is catchable",
        .source =
        \\function rejectsDepth(text) {
        \\  try { JSON.parse(text); return false; }
        \\  catch (error) { return error instanceof RangeError && error.message === "Maximum call stack size exceeded."; }
        \\}
        \\let shallow = "[".repeat(96) + "7" + "]".repeat(96);
        \\let value = JSON.parse(shallow);
        \\for (let i = 0; i < 96; i++) value = value[0];
        \\let revived = JSON.parse(shallow, function (key, child) { return child; });
        \\for (let i = 0; i < 96; i++) revived = revived[0];
        \\let syntax = false;
        \\try { JSON.parse("[1,"); } catch (error) { syntax = error instanceof SyntaxError; }
        \\let arrays = rejectsDepth("[".repeat(50000) + "0" + "]".repeat(50000));
        \\let objects = rejectsDepth("{\"v\":".repeat(50000) + "0" + "}".repeat(50000));
        \\let mixed = rejectsDepth("[{\"v\":".repeat(20000) + "0" + "}]".repeat(20000));
        \\let raw = false;
        \\try { JSON.rawJSON("[".repeat(50000) + "0" + "]".repeat(50000)); }
        \\catch (error) { raw = error instanceof RangeError && error.message === "Maximum call stack size exceeded."; }
        \\value === 7 && revived === 7 && syntax && arrays && objects && mixed && raw ? 1 : 0
        ,
        .expected = 1,
    },
};

const concurrency_cases = [_]Case{
    .{
        // #938: each interpreter reads its stack floor on the thread that
        // evaluates. A spawned Thread has its own stack, so a floor taken from
        // another thread would either fail every node or guard nothing. Shallow
        // nesting must evaluate there, and deep nesting must end in RangeError.
        .name = "nesting guard uses the evaluating thread's stack",
        .source =
        \\const t = new Thread(() => {
        \\  const outcome = run => { try { run(); return 1; } catch (e) { return e instanceof RangeError ? 2 : 0; } };
        \\  const shallow = outcome(() => (0, eval)("var x; " + "if (1) ".repeat(300) + "x = 1;"));
        \\  let deep = 1;
        \\  for (let n = 1000; n <= 512000 && deep === 1; n *= 2) deep = outcome(() => (0, eval)("var x; " + "if (1) ".repeat(n) + "x = 1;"));
        \\  return shallow * 10 + deep;
        \\});
        \\t.join()
        ,
        .expected = 12,
    },
    .{
        .name = "atomic increments",
        .source =
        \\const sab = new SharedArrayBuffer(4);
        \\const v = new Int32Array(sab);
        \\const threads = [];
        \\for (let i = 0; i < 4; i++) threads.push(new Thread(view => {
        \\  for (let j = 0; j < 500; j++) Atomics.add(view, 0, 1);
        \\}, v));
        \\for (const thread of threads) thread.join();
        \\v[0]
        ,
        .expected = 2000,
    },
    .{
        .name = "distinct property publication",
        .source =
        \\const o = { a: 0, b: 0 };
        \\const a = new Thread(value => { value.a = 11; }, o);
        \\const b = new Thread(value => { value.b = 31; }, o);
        \\a.join(); b.join(); o.a + o.b
        ,
        .expected = 42,
    },
    .{
        .name = "join chain",
        .source =
        \\const a = new Thread(() => 1);
        \\const b = new Thread(() => a.join() + 1);
        \\const c = new Thread(() => b.join() + 1);
        \\c.join()
        ,
        .expected = 3,
    },
};

fn matchesFilter(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.mem.indexOf(u8, name, filter) != null;
}

fn evaluateNumber(gpa: std.mem.Allocator, case: Case, enable_jit: bool, enable_threads: bool) !f64 {
    const ctx = try js.Context.createWith(gpa, .{
        .enable_jit = enable_jit,
        .enable_threads = enable_threads,
    });
    defer ctx.destroy();
    const result = ctx.evaluate(case.source) catch |err| {
        std.debug.print("focused engine test '{s}' threw {s}\n", .{ case.name, @errorName(err) });
        return error.FocusedTestFailed;
    };
    if (!result.isNumber()) {
        std.debug.print("focused engine test '{s}' returned a non-number\n", .{case.name});
        return error.FocusedTestFailed;
    }
    return result.asNum();
}

fn expectCase(gpa: std.mem.Allocator, case: Case, enable_jit: bool, enable_threads: bool) !void {
    const actual = try evaluateNumber(gpa, case, enable_jit, enable_threads);
    if (actual != case.expected) {
        std.debug.print("focused engine test '{s}': got {d}, expected {d}\n", .{ case.name, actual, case.expected });
        return error.FocusedTestFailed;
    }
}

fn runCases(gpa: std.mem.Allocator, cases: []const Case, filter: []const u8, enable_jit: bool, enable_threads: bool) !usize {
    var ran: usize = 0;
    for (cases) |case| {
        if (!matchesFilter(case.name, filter)) continue;
        try expectCase(gpa, case, enable_jit, enable_threads);
        ran += 1;
    }
    return ran;
}

fn runErrorCases(gpa: std.mem.Allocator, cases: []const ErrorCase, filter: []const u8) !usize {
    var ran: usize = 0;
    for (cases) |case| {
        if (!matchesFilter(case.name, filter)) continue;
        const ctx = try js.Context.create(gpa);
        defer ctx.destroy();
        if (ctx.evaluate(case.source)) |_| {
            std.debug.print("focused frontend test '{s}' unexpectedly parsed\n", .{case.name});
            return error.FocusedTestFailed;
        } else |_| {}
        ran += 1;
    }
    return ran;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const suite = args.next() orelse return error.MissingSuite;
    const filter = args.next() orelse "";
    const gpa = std.heap.page_allocator;

    const ran = if (std.mem.eql(u8, suite, "frontend")) blk: {
        const valid = try runCases(gpa, &frontend_cases, filter, false, false);
        const invalid = try runErrorCases(gpa, &frontend_error_cases, filter);
        break :blk valid + invalid;
    } else if (std.mem.eql(u8, suite, "vm"))
        try runCases(gpa, &vm_cases, filter, false, false)
    else if (std.mem.eql(u8, suite, "runtime"))
        try runCases(gpa, &runtime_cases, filter, false, false)
    else if (std.mem.eql(u8, suite, "jit")) blk: {
        const interpreted = try runCases(gpa, &jit_cases, filter, false, false);
        const native = try runCases(gpa, &jit_cases, filter, true, false);
        if (interpreted != native) return error.FocusedTestFailed;
        break :blk native;
    } else if (std.mem.eql(u8, suite, "concurrency"))
        try runCases(gpa, &concurrency_cases, filter, true, true)
    else
        return error.UnknownSuite;

    if (ran == 0) {
        std.debug.print("focused engine suite '{s}' matched no cases for filter '{s}'\n", .{ suite, filter });
        return error.NoMatchingCases;
    }
    std.debug.print("focused engine {s}: {d} case{s} passed\n", .{ suite, ran, if (ran == 1) "" else "s" });
}
