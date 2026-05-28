const std = @import("std");
const interp = @import("interpreter.zig");
const value = @import("value.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const Shape = @import("shape.zig").Shape;
const Parser = @import("parser.zig").Parser;

pub const RunError = interp.EvalError || @import("parser.zig").ParseError;

/// An isolated engine instance — the homegrown analogue of a JSC
/// `JSGlobalContextRef`. Owns an arena for all interpreter-lived allocations
/// (AST, strings, objects, boxed values) and a persistent global environment
/// so variables survive across `evaluate` calls, like a real global context.
pub const Context = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    env: interp.Environment,
    global_object: *value.Object,
    /// The empty root shape every object in this context transitions from.
    root_shape: *Shape,
    exception: ?value.Value = null,

    pub fn create(gpa: std.mem.Allocator) !*Context {
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        errdefer {
            arena_state.deinit();
            gpa.destroy(arena_state);
        }
        const a = arena_state.allocator();

        const global_obj = try a.create(value.Object);
        global_obj.* = .{};

        const self = try gpa.create(Context);
        self.* = .{
            .gpa = gpa,
            .arena_state = arena_state,
            .env = .{ .arena = a },
            .global_object = global_obj,
            .root_shape = try Shape.createRoot(a),
        };
        try interp.installGlobals(&self.env, self.root_shape);
        return self;
    }

    /// An interpreter bound to this context's arena, globals, and shape tree.
    pub fn interpreter(self: *Context) interp.Interpreter {
        return .{ .arena = self.arena(), .env = &self.env, .root_shape = self.root_shape };
    }

    pub fn destroy(self: *Context) void {
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
        self.gpa.destroy(self);
    }

    pub fn arena(self: *Context) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// Lex + parse + run `source`, returning the completion value. On an
    /// uncaught JS exception this returns `error.Throw` and leaves the thrown
    /// value in `self.exception` for the caller (e.g. the C-API boundary).
    ///
    /// Fast path: compile to bytecode and run on the VM. Programs that use
    /// constructs the compiler doesn't lower yet fall back to the tree-walker,
    /// so behavior is identical either way — the VM just handles the hot subset.
    pub fn evaluate(self: *Context, source: []const u8) RunError!value.Value {
        const a = self.arena();
        var parser = try Parser.init(a, source);
        const prog = try parser.parseProgram();
        var machine = self.interpreter();
        self.exception = null;

        if (compiler.Compiler.compileProgram(a, prog)) |chunk| {
            return vm.run(&machine, chunk, null) catch |err| {
                if (err == error.Throw) self.exception = machine.exception;
                return err;
            };
        } else |err| switch (err) {
            error.Unsupported => {}, // fall through to the tree-walker
            error.OutOfMemory => return error.OutOfMemory,
        }

        return machine.eval(prog) catch |err| {
            if (err == error.Throw) self.exception = machine.exception;
            return err;
        };
    }
};

test "Date basics" {
    // Components constructor (month is 0-based) + UTC getters.
    try std.testing.expectEqual(@as(f64, 2020), (try evalIn("new Date(2020, 0, 15).getUTCFullYear()")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Date(2020, 0, 15).getUTCMonth()")).number);
    try std.testing.expectEqual(@as(f64, 15), (try evalIn("new Date(2020, 0, 15).getUTCDate()")).number);
    // Epoch round-trips.
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Date(0).getTime()")).number);
    try std.testing.expectEqual(@as(f64, 1970), (try evalIn("new Date(0).getUTCFullYear()")).number);
    try expectEvalStr("number", "typeof Date.now()");
    try expectEvalStr("1970-01-01T00:00:00.000Z", "new Date(0).toISOString()");
    try std.testing.expect((try evalIn("typeof new Date() === 'object'")).boolean);
}

test "String generics + .constructor + match/search" {
    // String.prototype method on a non-string this (coerced).
    try expectEvalStr("123", "String.prototype.trim.call(123)");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("String.prototype.indexOf.call(12345, '3')")).number);
    // .constructor falls back to the kind's global.
    try std.testing.expect((try evalIn("[].constructor === Array")).boolean);
    try std.testing.expect((try evalIn("({}).constructor === Object")).boolean);
    try std.testing.expect((try evalIn("'x'.constructor === String")).boolean);
    try std.testing.expect((try evalIn("(5).constructor === Number")).boolean);
    // search / match.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("'abcd'.search(/cd/)")).number);
    try std.testing.expect((try evalIn("'hello'.match(/l+/)[0] === 'll'")).boolean);
    try expectEvalStr("abc", "'abc'.normalize()");
}


test "Array.prototype generics on array-likes" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\var o = { length: 3, 0: 1, 1: 2, 2: 3 };
        \\Array.prototype.reduce.call(o, function (a, b) { return a + b; }, 0)
    )).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var o = { length: 3, 0: 'a', 1: 'b', 2: 'c' };
        \\Array.prototype.indexOf.call(o, 'b')
    )).number);
    try expectEvalStr("a-b-c",
        \\var o = { length: 3, 0: 'a', 1: 'b', 2: 'c' };
        \\Array.prototype.join.call(o, '-')
    );
    try std.testing.expect((try evalIn(
        \\var o = { length: 2, 0: 10, 1: 20 };
        \\Array.prototype.every.call(o, function (x) { return x >= 10; })
    )).boolean);
}

test "Array / Object constructors" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(3).length")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Array(1, 2).length")).number);
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("var a = new Array(5, 6, 7); a[2]")).number);
    try expectEvalStr("function", "typeof Array");
    try std.testing.expect((try evalIn("var o = new Object(); typeof o === 'object'")).boolean);
    try std.testing.expect((try evalIn("var x = {}; Object(x) === x")).boolean);
    // Invalid array length throws RangeError.
    try std.testing.expect((try evalIn("var t = false; try { new Array(-1); } catch (e) { t = e.name === 'RangeError'; } t")).boolean);
}

test "destructuring catch parameter" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var r = 0;
        \\try { throw { a: 1, b: 2 }; } catch ({ a, b }) { r = a + b; }
        \\r
    )).number);
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\var r = 0;
        \\try { throw [10, 20]; } catch ([x, y]) { r = x + y; }
        \\r
    )).number);
}

test "Array.from with iterables + map fn" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\Array.from(g()).length + 3
    )).number);
    try std.testing.expectEqual(@as(f64, 12), (try evalIn("Array.from([1,2,3], function(x){return x*2;}).reduce(function(a,b){return a+b;},0)")).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("Array.from('abc').length")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Array.from({length: 2}).length")).number);
}

test "spread of iterables (generator, string, user iterator)" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\var a = [...g()]; a[0] + a[1] + a[2]
    )).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("[...'abc'].length")).number);
    // Spread feeding a call.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function add(a, b, c) { return a + b + c; }
        \\add(...[1, 2, 3])
    )).number);
}

test "Symbol: typeof, identity, description, property keys, iterator" {
    try expectEvalStr("symbol", "typeof Symbol()");
    try std.testing.expect((try evalIn("var s = Symbol(); s === s && Symbol() !== Symbol()")).boolean);
    try expectEvalStr("d", "Symbol('d').description");
    try expectEvalStr("symbol", "typeof Symbol.iterator");
    // Symbol-keyed property: works, but invisible to string enumeration.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var s = Symbol(); var o = { a: 1 }; o[s] = 5;
        \\o[s]
    )).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var s = Symbol(); var o = { a: 1 }; o[s] = 5;
        \\Object.keys(o).length
    )).number);
    // User iterator via Symbol.iterator drives for-of.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var obj = {};
        \\obj[Symbol.iterator] = function () {
        \\  var i = 0;
        \\  return { next: function () { return i < 3 ? { value: i++, done: false } : { value: undefined, done: true }; } };
        \\};
        \\var s = 0; for (var x of obj) { s += x; } s
    )).number);
}

test "array literal elision (holes)" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var a = [1, , 3]; a.length")).number);
    try std.testing.expectEqual(@as(f64, 4), (try evalIn("var a = [, , 4]; a[2]")).number);
    // Elision in array destructuring assignment.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("var a, b; [, a, , b] = [1, 2, 3, 4]; a")).number);
    try std.testing.expectEqual(@as(f64, 4), (try evalIn("var a, b; [, a, , b] = [1, 2, 3, 4]; b")).number);
}

test "new.target" {
    // undefined in a plain call, the constructor under `new`.
    try std.testing.expect((try evalIn(
        \\function F() { return new.target === F; }
        \\F() === false && new F() instanceof F
    )).boolean);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var hit = 0;
        \\function F() { if (new.target) hit = 1; }
        \\new F(); hit
    )).number);
}

test "object spread" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\var base = { a: 1, b: 2 };
        \\var o = { ...base, c: 3 };
        \\o.a + o.b + o.c
    )).number);
    // Later properties override earlier spread ones.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn("var o = { x: 1, ...{ x: 9 } }; o.x")).number);
    // Spreading null/undefined is a no-op.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var o = { ...null, ...undefined, a: 1 }; o.a")).number);
}

test "delete operator" {
    try std.testing.expect((try evalIn(
        \\var o = { a: 1, b: 2 };
        \\var ok = delete o.a;
        \\ok && !("a" in o) && o.b === 2
    )).boolean);
    // Non-configurable property can't be deleted.
    try std.testing.expect((try evalIn(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 1, configurable: false });
        \\var r = delete o.x;
        \\!r && ("x" in o)
    )).boolean);
    // delete of a non-reference / missing property is true.
    try std.testing.expect((try evalIn("delete 1 && delete {}.nope")).boolean);
}

test "for-of / for-in with destructuring + member targets" {
    try std.testing.expectEqual(@as(f64, 10), (try evalIn(
        \\var s = 0; for (const [a, b] of [[1, 2], [3, 4]]) { s += a + b; } s
    )).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var s = 0; for (const { x } of [{ x: 1 }, { x: 2 }]) { s += x; } s
    )).number);
    // Assignment form with a member target.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var o = {}; for (o.k of [5, 6, 7]) {} o.k
    )).number);
    // Plain identifier (regression) + for-in still work.
    try expectEvalStr("ab",
        \\var r = ""; for (var k in { a: 1, b: 2 }) { r += k; } r
    );
}

test "empty statements + class-declaration sequencing" {
    // A `;` after a class declaration (and stray `;`) no longer breaks the
    // following statements.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\class C { m() { return 2; } };
        \\var c = new C();
        \\c.m()
    )).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(";;; var x = 5;;; x")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\class C { [1.1]() { return 2; } static [1.1]() { return 2; } };
        \\var c = new C();
        \\c[1.1]()
    )).number);
}

test "context persists globals across evaluations" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate("var counter = 41;");
    const v = try ctx.evaluate("counter = counter + 1;");
    try std.testing.expectEqual(@as(f64, 42), v.number);
}

/// Evaluate `src` in a fresh context and return its completion value. Only safe
/// for by-value results (numbers/booleans); a returned `.string` points into the
/// context arena, so use `expectEvalStr` for those (it compares before teardown).
fn evalIn(src: []const u8) !value.Value {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    return ctx.evaluate(src);
}

/// Evaluate `src` and assert its string completion value, while the context (and
/// thus the string's backing arena) is still alive.
fn expectEvalStr(expected: []const u8, src: []const u8) !void {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    const v = try ctx.evaluate(src);
    try std.testing.expectEqualStrings(expected, v.string);
}

test "function name + length own properties" {
    // `name` and `length` are own, non-enumerable, configurable, non-writable.
    try expectEvalStr("foo", "function foo(a, b) {} foo.name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("function foo(a, b) {} foo.length")).number);
    try std.testing.expect((try evalIn(
        \\function foo(a, b) {}
        \\foo.hasOwnProperty("name") && foo.hasOwnProperty("length")
    )).boolean);
    // `length` counts params before the first default / rest.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("function f(a, b = 1, c) {} f.length")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("function f(a, ...r) {} f.length")).number);
    // Anonymous function expression has the empty name.
    try expectEvalStr("", "var f = function (x) {}; f.name");
    // Descriptor attributes: { writable:false, enumerable:false, configurable:true }.
    try std.testing.expect((try evalIn(
        \\function f() {}
        \\var d = Object.getOwnPropertyDescriptor(f, "length");
        \\!d.writable && !d.enumerable && d.configurable
    )).boolean);
    // name/length are not enumerable (skipped by Object.keys / for-in).
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("function f(a) {} Object.keys(f).length")).number);
    // Class constructor carries name + constructor arity.
    try expectEvalStr("C", "class C { constructor(a, b) {} } C.name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("class C { constructor(a, b) {} } C.length")).number);
    // Bound function: name is "bound <target>", length is reduced by bound args.
    try expectEvalStr("bound f", "function f(a, b, c) {} f.bind(null, 1).name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("function f(a, b, c) {} f.bind(null, 1).length")).number);
}

test "native functions carry name + length own properties" {
    // Built-in methods/globals/constructors report their spec name and arity.
    try expectEvalStr("defineProperty", "Object.defineProperty.name");
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("Object.defineProperty.length")).number);
    try expectEvalStr("push", "Array.prototype.push.name");
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("Array.prototype.push.length")).number);
    try expectEvalStr("parseInt", "parseInt.name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("parseInt.length")).number);
    try expectEvalStr("Object", "Object.name");
    // Same name can have a different arity on a different prototype.
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Object.prototype.toString.length")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("Number.prototype.toString.length")).number);
    // Own + non-enumerable + non-writable + configurable, like user functions.
    try std.testing.expect((try evalIn(
        \\Object.keys.hasOwnProperty("name") && Object.keys.hasOwnProperty("length")
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var d = Object.getOwnPropertyDescriptor(Math.max, "length");
        \\!d.writable && !d.enumerable && d.configurable
    )).boolean);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Object.keys(Math.floor).length")).number);
}

test "Date setters + string conversions" {
    // Time-component setters honor extra args and roll over out-of-range values.
    try std.testing.expect((try evalIn(
        \\var d = new Date(2016, 6, 1); d.setHours(0, 0, 0, 543);
        \\d.getTime() === new Date(2016, 6, 1, 0, 0, 0, 543).getTime()
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var d = new Date(2016, 6, 1); d.setHours(0, 0, 0, -1);
        \\d.getTime() === new Date(2016, 5, 30, 23, 59, 59, 999).getTime()
    )).boolean);
    // setMonth/setDate roll into adjacent months/years.
    try std.testing.expectEqual(@as(f64, 1971), (try evalIn("var d = new Date(0); d.setMonth(13); d.getUTCFullYear()")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var d = new Date(0); d.setDate(32); d.getUTCMonth()")).number);
    // setFullYear revives an invalid date; other setters leave it invalid.
    try std.testing.expectEqual(@as(f64, 2020), (try evalIn("var d = new Date(NaN); d.setFullYear(2020); d.getUTCFullYear()")).number);
    try std.testing.expect(std.math.isNan((try evalIn("var d = new Date(NaN); d.setHours(5); d.getTime()")).number));
    // String conversions.
    try expectEvalStr("Thu, 01 Jan 1970 00:00:00 GMT", "new Date(0).toUTCString()");
    try expectEvalStr("Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)", "new Date(0).toString()");
    try expectEvalStr("Thu Jan 01 1970", "new Date(0).toDateString()");
    try expectEvalStr("00:00:00 GMT+0000 (Coordinated Universal Time)", "new Date(0).toTimeString()");
    // toISOString throws RangeError on an invalid date; toJSON returns null.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { new Date(NaN).toISOString(); } catch (e) { t = e.name === "RangeError"; }
        \\t
    )).boolean);
    try std.testing.expect((try evalIn("new Date(NaN).toJSON() === null")).boolean);
}

test "Function constructor builds callable functions from source" {
    // Params + body, called and constructed.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("Function('a', 'b', 'return a + b')(3, 4)")).number);
    try std.testing.expectEqual(@as(f64, 12), (try evalIn("new Function('a,b', 'return a * b')(3, 4)")).number);
    try std.testing.expectEqual(@as(f64, 42), (try evalIn("Function('return 42')()")).number);
    // Spec name + arity of the synthesized function.
    try expectEvalStr("anonymous", "Function('return 1').name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Function('a', 'b', 'return 0').length")).number);
    try expectEvalStr("function", "typeof Function('return 1')");
    // A syntactically invalid body throws SyntaxError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Function("return )("); } catch (e) { t = e.name === "SyntaxError"; }
        \\t
    )).boolean);
}

test "String.prototype.split: limit + regex separators" {
    // `limit` truncates the result.
    try expectEvalStr("a|b", "'a,b,c'.split(',', 2).join('|')");
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("'a,b,c'.split(',', 0).length")).number);
    // Regex separators split on each match.
    try expectEvalStr("2016|01|02", "'2016-01-02'.split(/-/).join('|')");
    try expectEvalStr("a|b|c", "'a1b2c'.split(/\\d/).join('|')");
    try expectEvalStr("a|b|c", "'a, b ,c'.split(/\\s*,\\s*/).join('|')");
    // An empty-matching pattern splits between every character.
    try expectEvalStr("a|b|c", "'abc'.split(/(?:)/).join('|')");
    // Capture groups are spliced into the result.
    try expectEvalStr(",t,es,t,", "'test'.split(/(t)/).join(',')");
    // Empty input: [""] unless the pattern matches the empty string (then []).
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("''.split(/x/).length")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("''.split(/(?:)/).length")).number);
    // String separators (and no separator) still behave.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("'a,b,c'.split(',').length")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("'abc'.split().length")).number);
}

test "Object.hasOwn" {
    try std.testing.expect((try evalIn("Object.hasOwn({ a: 1 }, \"a\")")).boolean);
    try std.testing.expect(!(try evalIn("Object.hasOwn({ a: 1 }, \"b\")")).boolean);
    // Own only — inherited properties are excluded.
    try std.testing.expect(!(try evalIn("Object.hasOwn(Object.create({ a: 1 }), \"a\")")).boolean);
    // Array indices, array length, and string indices/length.
    try std.testing.expect((try evalIn("Object.hasOwn([1, 2], 0) && Object.hasOwn([1, 2], \"length\") && !Object.hasOwn([1, 2], 5)")).boolean);
    try std.testing.expect((try evalIn("Object.hasOwn(\"ab\", 0) && Object.hasOwn(\"ab\", \"length\") && !Object.hasOwn(\"ab\", 9)")).boolean);
    // null / undefined throw a TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.hasOwn(null, "x"); } catch (e) { t = e.name === "TypeError"; }
        \\t
    )).boolean);
}

test "defineProperty rejects incompatible redefinition of non-configurable props" {
    // A non-configurable property can't be made configurable, re-typed, or (when
    // non-writable) have its value/writability changed — each throws TypeError.
    const cases = [_][]const u8{
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, configurable: false });
        \\Object.defineProperty(o, "p", { value: 2 });
        ,
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, configurable: false });
        \\Object.defineProperty(o, "p", { configurable: true });
        ,
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, configurable: false });
        \\Object.defineProperty(o, "p", { enumerable: true });
        ,
        \\var a = []; Object.defineProperty(a, "0", { value: -0 });
        \\Object.defineProperties(a, { "0": { value: 0 } });
        ,
        \\var o = Object.freeze({}); Object.defineProperty(o, "x", { value: 1 });
    };
    for (cases) |src| {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        try std.testing.expectError(error.Throw, ctx.evaluate(src));
        try std.testing.expectEqualStrings("TypeError", ctx.exception.?.object.error_name);
    }
    // Compatible redefinitions are still allowed.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, configurable: true });
        \\Object.defineProperty(o, "p", { value: 2 }); o.p
    )).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, writable: true, configurable: false });
        \\Object.defineProperty(o, "p", { value: 2 }); o.p
    )).number);
}

test "Object.create applies its properties (second) argument" {
    // Data descriptor on the new object.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn(
        \\var o = Object.create({}, { x: { value: 42, enumerable: true } });
        \\o.x
    )).number);
    // Accessor descriptor.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var o = Object.create(null, { a: { get: function () { return 7; }, enumerable: true } });
        \\o.a
    )).number);
    // Descriptor attributes are honored (non-enumerable stays off Object.keys).
    try std.testing.expectEqual(@as(f64, 0), (try evalIn(
        \\var o = Object.create({}, { a: { value: 1, enumerable: false } });
        \\Object.keys(o).length
    )).number);
    // The prototype argument still wires up the chain; omitted props is a no-op.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var p = { v: 5 }; var o = Object.create(p); o.v
    )).number);
    // A non-object descriptor value throws TypeError, like defineProperties.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.create({}, { x: 1 }); } catch (e) { t = e.name === "TypeError"; }
        \\t
    )).boolean);
}

test "new on a non-constructor built-in throws TypeError" {
    // Methods, statics, globals and Symbol are not constructors.
    for ([_][]const u8{
        "new Object.keys({})",
        "new Math.max(1)",
        "new parseInt('1')",
        "new Array.from([])",
        "new Symbol()",
        "new [].push",
    }) |src| {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        try std.testing.expectError(error.Throw, ctx.evaluate(src));
        try std.testing.expect(ctx.exception.?.object.is_error);
        try std.testing.expectEqualStrings("TypeError", ctx.exception.?.object.error_name);
    }
    // The real constructors still build instances.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(3).length")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Date(0).getTime()")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Map().size")).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("new Number(5).valueOf()")).number);
    try std.testing.expect((try evalIn("typeof new Object() === 'object'")).boolean);
}

test "Function.prototype: call / apply / bind" {
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function add(a, b) { return a + b; }
        \\add.call(null, 3, 4)
    )).number);
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function add(a, b) { return a + b; }
        \\add.apply(null, [3, 4])
    )).number);
    // `this` binding via call.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn(
        \\function getX() { return this.x; }
        \\getX.call({ x: 42 })
    )).number);
    // bind fixes `this` and leading args.
    try std.testing.expectEqual(@as(f64, 15), (try evalIn(
        \\function add3(a, b, c) { return a + b + c; }
        \\var f = add3.bind(null, 1, 2);
        \\f(12)
    )).number);
    try std.testing.expectEqual(@as(f64, 100), (try evalIn(
        \\var o = { v: 100, get: function () { return this.v; } };
        \\var g = o.get.bind(o);
        \\g()
    )).number);
}

test "prototype objects: Function.prototype.call.bind + X.prototype methods" {
    // The propertyHelper pattern: borrow a prototype method via call.bind.
    try expectEvalStr("1-2-3",
        \\var __join = Function.prototype.call.bind(Array.prototype.join);
        \\__join([1, 2, 3], "-")
    );
    try std.testing.expect((try evalIn(
        \\var __hasOwn = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
        \\__hasOwn({ a: 1 }, "a") && !__hasOwn({ a: 1 }, "b")
    )).boolean);
    // Direct prototype-method access + .call.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\Array.prototype.indexOf.call([10, 20, 30], 30) + 1
    )).number);
}

test "property descriptors: defineProperty attrs + getOwnPropertyDescriptor" {
    // defineProperty defaults omitted attrs to false; getOwnPropertyDescriptor reports them.
    try std.testing.expect((try evalIn(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 5 });
        \\var d = Object.getOwnPropertyDescriptor(o, "x");
        \\d.value === 5 && d.writable === false && d.enumerable === false && d.configurable === false
    )).boolean);
    // A non-writable property ignores assignment (sloppy mode).
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 5, writable: false });
        \\o.x = 99;
        \\o.x
    )).number);
    // Non-enumerable property is skipped by Object.keys / for-in but kept by getOwnPropertyNames.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.defineProperty(o, "hidden", { value: 2, enumerable: false });
        \\Object.keys(o).length === 1 && Object.getOwnPropertyNames(o).length === 2 &&
        \\  !o.propertyIsEnumerable("hidden") && o.propertyIsEnumerable("a")
    )).boolean);
    // Plain-assignment properties are writable/enumerable/configurable.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\var d = Object.getOwnPropertyDescriptor(o, "a");
        \\d.writable && d.enumerable && d.configurable
    )).boolean);
}

test "Object.freeze / seal / preventExtensions" {
    // freeze: writes ignored, not extensible, isFrozen true.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.freeze(o);
        \\o.a = 2; o.b = 3;
        \\o.a === 1 && o.b === undefined && Object.isFrozen(o) && !Object.isExtensible(o)
    )).boolean);
    // seal: existing writable, but no new props, isSealed true (not frozen).
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.seal(o);
        \\o.a = 9; o.b = 3;
        \\o.a === 9 && o.b === undefined && Object.isSealed(o) && !Object.isFrozen(o)
    )).boolean);
    // preventExtensions: can't add, can still modify.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.preventExtensions(o);
        \\o.b = 3; o.a = 5;
        \\o.a === 5 && o.b === undefined && !Object.isExtensible(o)
    )).boolean);
    // empty frozen object is frozen.
    try std.testing.expect((try evalIn("Object.isFrozen(Object.freeze({}))")).boolean);
}

test "Object.prototype: hasOwnProperty / isPrototypeOf" {
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 }; o.hasOwnProperty("a")
    )).boolean);
    try std.testing.expect(!(try evalIn(
        \\var o = { a: 1 }; o.hasOwnProperty("b")
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var a = [1, 2, 3]; a.hasOwnProperty("length") && a.hasOwnProperty(0) && !a.hasOwnProperty(9)
    )).boolean);
}

test "generators: manual next() yields values then done" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\var it = g();
        \\var a = it.next().value, b = it.next().value, c = it.next().value;
        \\a + b + c
    )).number);
    // After exhaustion, next().done is true and value undefined.
    try std.testing.expect((try evalIn(
        \\function* g() { yield 1; }
        \\var it = g(); it.next();
        \\it.next().done
    )).boolean);
}

test "generators: for-of drives the generator" {
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\function* g() { yield 10; yield 20; }
        \\var s = 0; for (var x of g()) { s += x; } s
    )).number);
}

test "generators: next(v) is the value of the resumed yield" {
    try std.testing.expectEqual(@as(f64, 15), (try evalIn(
        \\function* g() { var x = yield 1; yield x + 10; }
        \\var it = g(); it.next(); it.next(5).value
    )).number);
}

test "generators: infinite generator bounded by the consumer" {
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\function* nat() { var i = 0; while (true) { yield i; i = i + 1; } }
        \\var it = nat(); it.next(); it.next(); it.next().value
    )).number);
}

test "generators: yield* delegates to arrays, strings, and generators" {
    // Delegate to an array.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield* [1, 2, 3]; }
        \\var s = 0; for (var x of g()) { s += x; } s
    )).number);
    // Delegate to another generator, interleaved with own yields.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* inner() { yield 1; yield 2; }
        \\function* outer() { yield 0; yield* inner(); yield 3; }
        \\var s = 0; for (var x of outer()) { s += x; } s
    )).number);
    // Delegate to a string (yields each character).
    try expectEvalStr("ab",
        \\function* g() { yield* "ab"; }
        \\var it = g(); it.next().value + it.next().value
    );
    // `yield*` evaluates to the delegated generator's return value.
    try std.testing.expectEqual(@as(f64, 99), (try evalIn(
        \\function* inner() { yield 1; return 99; }
        \\function* outer() { var r = yield* inner(); yield r; }
        \\var it = outer(); it.next(); it.next().value
    )).number);
}

test "generators: a return value finishes with done:true" {
    try std.testing.expectEqual(@as(f64, 99), (try evalIn(
        \\function* g() { yield 1; return 99; }
        \\var it = g(); it.next(); it.next().value
    )).number);
}

test "generators: locals persist across yields, closures captured" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var base = 1;
        \\function* g() { var n = base; yield n; n = n + 1; yield n; }
        \\var it = g(); it.next(); it.next().value + base
    )).number);
}
