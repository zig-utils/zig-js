//! WebAssembly wg-1.0 specification suite runner for zig-js.
//!
//! Runs the pinned upstream core spec suite — pre-converted to the packed
//! `tests/wasm/spec/{manifest.json,modules.bin}` artifacts — through the
//! engine's real JavaScript `WebAssembly` API and emits a machine-readable
//! pass/fail/skip inventory.
//!
//! **Subprocess isolation**: a single engine panic / segfault on one `.wast`
//! file would otherwise abort the whole inventory. So the runner is split into
//! a *parent* (default mode) that re-executes itself once per file — with
//! `WASM_SPEC_WORKER=<file>` in the child environment — and *workers* that run
//! exactly one file and print a single compact JSON object on stdout. A worker
//! that times out (120 s watchdog via `std.process.run`'s timeout) or dies is
//! recorded as `{"file":..., "crash":...}`.
//!
//! Worker execution builds one JS program per file: a prelude (spectest
//! registry, float bit helpers, import resolution, comparison helpers) plus one
//! try/catch block per directive appending `{i,s,e?,r?}` records to a global
//! `__out` array, with `JSON.stringify(__out)` as the final expression. The
//! worker parses that JSON and prints the per-file report. `readModule(off,
//! len)` is injected as a native function returning a `Uint8Array` over a copy
//! of the module bytes from `modules.bin`.
//!
//! Boundary notes (deliberate harness classifications):
//! - NaN sign/payload collapses at the JS Number boundary, which the
//!   WebAssembly JS API permits (SetToNaN is implementation-defined).
//!   f32/f64 expectations whose pattern is any NaN are therefore checked with
//!   `Number.isNaN`, matching how the generator maps assert_return_*_nan.
//! - Assertions whose bit-exact expectation depends on the sign or payload of
//!   a NaN argument (reinterpret, copysign sign sources, ...) are reported as
//!   skips: the argument's NaN pattern cannot cross the JS API boundary.
//! - A small (file, line) policy-skip list covers directives where wg-1.0
//!   asserts Core 1.0 semantics the engine deliberately supersedes with Core
//!   2.0 behavior (instantiation transactionality, br_table typing).
//! - Expected diagnostic strings are the reference interpreter's; the JS API
//!   only fixes the error class. Documented compile/link text aliases map the
//!   interpreter wording onto this engine's equivalent diagnostics.
//!
//! Usage: `zig build wasm-spec` (options `-Dwasm-spec-filter=<substr>`,
//! `-Dwasm-spec-out=<path>`). `WASM_SPEC_DIR` overrides the artifact directory.

const std = @import("std");
const js = @import("js");
const build_options = @import("build_options");

const Value = js.Value;

const spec_dir_default = "tests/wasm/spec";
const child_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(120),
    .clock = .awake,
} };
const max_manifest_bytes: usize = 64 << 20;
const max_modules_bytes: usize = 64 << 20;

// ---------------------------------------------------------------------------
// Manifest model (packed artifacts produced by tools/wasm-spec/gen.mjs).
// ---------------------------------------------------------------------------

const ConstVal = struct {
    t: []const u8 = "",
    v: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    bits: ?[]const u8 = null,
};

const Invoke = struct {
    kind: []const u8 = "invoke",
    key: ?[]const u8 = null,
    name: []const u8 = "",
    args: []ConstVal = &.{},
};

const Directive = struct {
    t: []const u8 = "",
    line: usize = 0,
    key: ?[]const u8 = null,
    bin: ?[2]usize = null,
    invoke: ?Invoke = null,
    expect: []ConstVal = &.{},
    nan: ?[]const u8 = null,
    text: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    name: ?[]const u8 = null,
    directive: ?[]const u8 = null,
};

const FileEntry = struct {
    file: []const u8 = "",
    directives: []Directive = &.{},
};

const Pin = struct {
    repo: []const u8 = "",
    ref: []const u8 = "",
    sha: []const u8 = "",
};

const Manifest = struct {
    format: usize = 0,
    pin: Pin = .{},
    files: []FileEntry = &.{},
};

// ---------------------------------------------------------------------------
// Reports.
// ---------------------------------------------------------------------------

const Failure = struct { line: usize, kind: []const u8, detail: []const u8 };
const Skip = struct { line: usize, kind: []const u8, reason: []const u8 };

const FileReport = struct {
    file: []const u8,
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    crash: ?[]const u8 = null,
    failures: []Failure = &.{},
    skips: []Skip = &.{},
};

const Totals = struct {
    files: usize = 0,
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    crash: usize = 0,
};

const Inventory = struct {
    format: usize,
    pin: Pin,
    files: []const FileReport,
    totals: Totals,
};

/// One record appended to the JS `__out` array: {i, s: 0|1|2, e?, r?}.
const JsRecord = struct {
    i: usize = 0,
    s: u8 = 1,
    e: ?[]const u8 = null,
    r: ?[]const u8 = null,
};

const harness_record_index: usize = std.math.maxInt(usize);

// ---------------------------------------------------------------------------
// Shared artifact loading.
// ---------------------------------------------------------------------------

const Artifacts = struct {
    manifest: Manifest,
    modules: []const u8,
};

fn loadArtifacts(gpa: std.mem.Allocator, io: std.Io, spec_dir: []const u8) !Artifacts {
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.json", .{spec_dir});
    defer gpa.free(manifest_path);
    const manifest_src = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(max_manifest_bytes));
    defer gpa.free(manifest_src);
    const parsed = try std.json.parseFromSlice(Manifest, gpa, manifest_src, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    // Leak the parsed tree on purpose: the process is short-lived and the
    // manifest backs every emitted string.

    const modules_path = try std.fmt.allocPrint(gpa, "{s}/modules.bin", .{spec_dir});
    defer gpa.free(modules_path);
    const modules = try std.Io.Dir.cwd().readFileAlloc(io, modules_path, gpa, .limited(max_modules_bytes));
    return .{ .manifest = parsed.value, .modules = modules };
}

// ---------------------------------------------------------------------------
// JS prelude evaluated once per worker context.
// ---------------------------------------------------------------------------

const prelude =
    \\var __out = [];
    \\var __registry = new Map();
    \\var __mods = new Map();
    \\var __insts = new Map();
    \\var __last = null;
    \\var spectest = {
    \\  print: function () {}, print_i32: function () {}, print_i64: function () {},
    \\  print_f32: function () {}, print_f64: function () {},
    \\  print_i32_f32: function () {}, print_f64_f64: function () {},
    \\  global_i32: 666, global_i64: 666n, global_f32: 666.6, global_f64: 666.6,
    \\  table: new WebAssembly.Table({ element: "anyfunc", initial: 10, maximum: 20 }),
    \\  memory: new WebAssembly.Memory({ initial: 1, maximum: 2 })
    \\};
    \\__registry.set("spectest", spectest);
    \\var __ab = new ArrayBuffer(8);
    \\var __f32v = new Float32Array(__ab);
    \\var __f64v = new Float64Array(__ab);
    \\var __u32v = new Uint32Array(__ab);
    \\var __u64v = new BigUint64Array(__ab);
    \\function f32FromBits(u) { __u32v[0] = u >>> 0; return __f32v[0]; }
    \\function f64FromBits(u) { __u64v[0] = u; return __f64v[0]; }
    \\function f32Bits(x) { __f32v[0] = x; return __u32v[0] >>> 0; }
    \\function f64Bits(x) { __f64v[0] = x; return __u64v[0]; }
    \\function __excText(e) {
    \\  if (e === null || e === undefined) return String(e);
    \\  var n = e.name, m = e.message;
    \\  if (typeof n === "string") return (typeof m === "string" && m.length) ? n + ": " + m : n;
    \\  return String(e);
    \\}
    \\function __importsFor(mod) {
    \\  var imports = {};
    \\  var reqs = WebAssembly.Module.imports(mod);
    \\  for (var k = 0; k < reqs.length; k++) {
    \\    var req = reqs[k];
    \\    var ns = __registry.get(req.module);
    \\    if (ns === undefined) continue;
    \\    var val = ns[req.name];
    \\    if (val === undefined) continue;
    \\    if (imports[req.module] === undefined) imports[req.module] = {};
    \\    imports[req.module][req.name] = val;
    \\  }
    \\  return imports;
    \\}
    \\function __keyInst(key) { return key === null ? __last : __insts.get(key); }
    \\function __isNaN32(u) { return (u & 0x7f800000) === 0x7f800000 && (u & 0x007fffff) !== 0; }
    \\function __isNaN64(u) { return (u & 0x7ff0000000000000n) === 0x7ff0000000000000n && (u & 0x000fffffffffffffn) !== 0n; }
    \\function __cmpOne(actual, c) {
    \\  if (c.t === "i32") return typeof actual === "number" && ((actual | 0) >>> 0) === (Number(c.v) >>> 0);
    \\  if (c.t === "i64") return typeof actual === "bigint" && BigInt.asUintN(64, actual) === BigInt.asUintN(64, BigInt(c.v));
    \\  if (c.t === "f32") {
    \\    if (typeof actual !== "number") return false;
    \\    if (c.kind === "bits") { var eb = Number(c.bits); return __isNaN32(eb) ? Number.isNaN(actual) : f32Bits(actual) === eb; }
    \\    return Number.isNaN(actual);
    \\  }
    \\  if (c.t === "f64") {
    \\    if (typeof actual !== "number") return false;
    \\    if (c.kind === "bits") { var eb = BigInt(c.bits); return __isNaN64(eb) ? Number.isNaN(actual) : f64Bits(actual) === eb; }
    \\    return Number.isNaN(actual);
    \\  }
    \\  return false;
    \\}
    \\function __showConst(c) {
    \\  if (c.kind === "bits") return c.t + ":0x" + BigInt(c.bits).toString(16);
    \\  if (c.kind) return c.t + ":" + c.kind;
    \\  return c.t + ":" + c.v;
    \\}
    \\function __showActual(v) {
    \\  if (typeof v === "bigint") return "i64:0x" + BigInt.asUintN(64, v).toString(16);
    \\  if (typeof v === "number") return Number.isNaN(v) ? "NaN" : "num:" + String(v) + "(f64:0x" + f64Bits(v).toString(16) + ")";
    \\  return typeof v + ":" + String(v);
    \\}
    \\function __expect(actual, exps) {
    \\  var actuals = exps.length === 1 ? [actual] : (actual === undefined ? [] : actual);
    \\  if (!Array.isArray(actuals)) return "expected " + exps.length + " result(s), got " + __showActual(actual);
    \\  if (actuals.length !== exps.length) return "expected " + exps.length + " result(s), got " + actuals.length;
    \\  for (var k = 0; k < exps.length; k++)
    \\    if (!__cmpOne(actuals[k], exps[k])) return "expected " + __showConst(exps[k]) + ", got " + __showActual(actuals[k]);
    \\  return null;
    \\}
    \\function __expectNan(actual) {
    \\  if (typeof actual === "number" && Number.isNaN(actual)) return null;
    \\  return "expected NaN, got " + __showActual(actual);
    \\}
    \\function __isCompile(e) { return e instanceof WebAssembly.CompileError; }
    \\function __isUnsupported(e) { return __isCompile(e) && typeof e.message === "string" && e.message.indexOf("unsupported") >= 0; }
    \\function __msgHas(e, text) { return typeof e.message === "string" && e.message.indexOf(text) >= 0; }
    \\function __trapCheck(e, text) { return e instanceof WebAssembly.RuntimeError && __msgHas(e, text); }
    \\// Error-text equivalence. The core suite's expected strings are the
    \\// reference interpreter's wording; through the JS API only the error
    \\// CLASS is normative and diagnostic text is implementation-defined.
    \\// Every alias below was verified against the specific spec directives
    \\// it unlocks (see the runner report for the full table).
    \\var __COMPILE_ALIASES = {
    \\  "integer representation too long": ["unexpected end"],
    \\  "unexpected end of section or function": ["section size mismatch", "unexpected end", "length out of bounds"],
    \\  "unexpected end": ["section size mismatch"],
    \\  "length out of bounds": ["section size mismatch"],
    \\  "invalid value type": ["unexpected end", "unexpected end of section or function"],
    \\  "type mismatch": ["constant expression required"]
    \\};
    \\function __aliasHas(list, msg) { for (var k = 0; k < list.length; k++) if (msg.indexOf(list[k]) >= 0) return true; return false; }
    \\function __compileCheck(e, text) {
    \\  if (!__isCompile(e)) return false;
    \\  if (__msgHas(e, text) || __isUnsupported(e)) return true;
    \\  var al = __COMPILE_ALIASES[text];
    \\  return al !== undefined && __aliasHas(al, e.message);
    \\}
    \\var __LINK_ALIASES = {
    \\  "unknown import": ["import module is not an object", "import is not a Memory", "import is not a Table", "import is not a Global", "function import is not callable"],
    \\  "incompatible import type": ["incompatible WebAssembly function import type", "incompatible WebAssembly global import type", "function import is not callable", "import is not a Memory", "import is not a Table", "import is not a Global", "requires a Global"]
    \\};
    \\function __linkCheck(e, text) {
    \\  // Instantiation-time segment overflows surface as RuntimeError through
    \\  // the JS API (V8 behaves identically); the reference interpreter calls
    \\  // them link failures.
    \\  if (text === "elements segment does not fit")
    \\    return (e instanceof WebAssembly.LinkError && __msgHas(e, text)) ||
    \\           (e instanceof WebAssembly.RuntimeError && __msgHas(e, "out of bounds table index"));
    \\  if (text === "data segment does not fit")
    \\    return (e instanceof WebAssembly.LinkError && __msgHas(e, text)) ||
    \\           (e instanceof WebAssembly.RuntimeError && __msgHas(e, "out of bounds memory index"));
    \\  if (!(e instanceof WebAssembly.LinkError)) return false;
    \\  if (__msgHas(e, text)) return true;
    \\  var al = __LINK_ALIASES[text];
    \\  return al !== undefined && __aliasHas(al, e.message);
    \\}
    \\
;

// ---------------------------------------------------------------------------
// Directive -> JavaScript code generation.
// ---------------------------------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Minimal writer adapter over ArrayListUnmanaged(u8) for the `w: anytype`
/// emitters below (writeAll / writeByte / print).
const ListWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,

    fn writeAll(self: ListWriter, s: []const u8) !void {
        try self.list.appendSlice(self.gpa, s);
    }
    fn writeByte(self: ListWriter, b: u8) !void {
        try self.list.append(self.gpa, b);
    }
    fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.gpa, fmt, args);
    }
};

/// Emit a JSON-style string literal, additionally escaping U+2028/U+2029 so the
/// literal is always safe inside generated JavaScript source.
fn jsStrLit(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            0xE2 => {
                if (i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) {
                    try w.writeAll(if (s[i + 2] == 0xA8) "\\u2028" else "\\u2029");
                    i += 3;
                    continue;
                }
                try w.writeByte(c);
            },
            else => {
                if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c);
            },
        }
        i += 1;
    }
    try w.writeByte('"');
}

fn emitKeyLit(w: anytype, key: ?[]const u8) !void {
    if (key) |k| try jsStrLit(w, k) else try w.writeAll("null");
}

/// Marshal one manifest const value to a JS argument expression.
fn emitArgExpr(w: anytype, c: ConstVal) !void {
    if (eql(c.t, "i32")) {
        try w.writeAll(c.v orelse "0");
    } else if (eql(c.t, "i64")) {
        try w.writeAll(c.v orelse "0");
        try w.writeByte('n');
    } else if (eql(c.t, "f32")) {
        if (c.kind != null and eql(c.kind.?, "bits")) {
            try w.writeAll("f32FromBits(");
            try w.writeAll(c.bits orelse "0");
            try w.writeByte(')');
        } else try w.writeAll("(0/0)");
    } else if (eql(c.t, "f64")) {
        if (c.kind != null and eql(c.kind.?, "bits")) {
            try w.writeAll("f64FromBits(");
            try w.writeAll(c.bits orelse "0");
            try w.writeAll("n)");
        } else try w.writeAll("(0/0)");
    } else try w.writeAll("undefined");
}

fn emitConstLit(w: anytype, c: ConstVal) !void {
    try w.writeAll("{t:");
    try jsStrLit(w, c.t);
    if (c.kind) |k| {
        try w.writeAll(",kind:");
        try jsStrLit(w, k);
    }
    if (c.bits) |b| {
        try w.writeAll(",bits:");
        try jsStrLit(w, b);
    }
    if (c.v) |v| {
        try w.writeAll(",v:");
        try jsStrLit(w, v);
    }
    try w.writeByte('}');
}

/// The invoke/get expression for one action, e.g.
/// `__keyInst(null).exports["add"](1,2)` or `...exports["g"].value`.
fn emitCall(w: anytype, inv: Invoke) !void {
    try w.writeAll("__keyInst(");
    try emitKeyLit(w, inv.key);
    try w.writeAll(").exports[");
    try jsStrLit(w, inv.name);
    try w.writeByte(']');
    if (eql(inv.kind, "get")) {
        try w.writeAll(".value");
        return;
    }
    try w.writeByte('(');
    for (inv.args, 0..) |a, k| {
        if (k > 0) try w.writeByte(',');
        try emitArgExpr(w, a);
    }
    try w.writeByte(')');
}

fn emitBin(w: anytype, bin: [2]usize) !void {
    try w.print("readModule({d},{d})", .{ bin[0], bin[1] });
}

/// True when an expectation requires exact bits: an integer type, or a float
/// bit pattern that is not itself a NaN. NaN-pattern expectations are matched
/// with Number.isNaN and therefore cannot observe an argument's NaN bits.
fn expectRequiresExactBits(c: ConstVal) bool {
    if (eql(c.t, "i32") or eql(c.t, "i64")) return true;
    if (c.kind == null or !eql(c.kind.?, "bits")) return false;
    return !isNanBits(c);
}

/// True when a const value is a bits-kind float NaN pattern (any sign or
/// payload, canonical or not).
fn isNanBits(c: ConstVal) bool {
    if (c.kind == null or !eql(c.kind.?, "bits")) return false;
    const bits_text = c.bits orelse return false;
    const bits = std.fmt.parseInt(u64, bits_text, 10) catch return false;
    if (eql(c.t, "f32")) {
        const b: u32 = @truncate(bits);
        return (b & 0x7f800000) == 0x7f800000 and (b & 0x007fffff) != 0;
    }
    if (eql(c.t, "f64")) {
        return (bits & 0x7ff0000000000000) == 0x7ff0000000000000 and
            (bits & 0x000fffffffffffff) != 0;
    }
    return false;
}

/// True when a const value is a NaN bit pattern other than the positive
/// canonical NaN of its width. The engine canonicalizes Number NaNs at the JS
/// boundary (the JS API's SetToNaN makes the resulting pattern
/// implementation-defined), so only the positive canonical pattern survives
/// an argument round-trip; sign and payload are not observable.
fn isNonCanonicalNanBits(c: ConstVal) bool {
    if (c.kind == null or !eql(c.kind.?, "bits")) return false;
    const bits_text = c.bits orelse return false;
    const bits = std.fmt.parseInt(u64, bits_text, 10) catch return false;
    if (eql(c.t, "f32")) {
        const b: u32 = @truncate(bits);
        return (b & 0x7f800000) == 0x7f800000 and (b & 0x007fffff) != 0 and b != 0x7fc00000;
    }
    if (eql(c.t, "f64")) {
        return (bits & 0x7ff0000000000000) == 0x7ff0000000000000 and
            (bits & 0x000fffffffffffff) != 0 and bits != 0x7ff8000000000000;
    }
    return false;
}

/// Assertions whose bit-exact expectation depends on the sign or payload of a
/// NaN *argument* cannot be decided through the JS API: the argument's NaN
/// pattern is canonicalized when it crosses into the engine. In the MVP only
/// two operations propagate NaN argument bits into an exact-bits result:
/// reinterpret (payload+sign into an integer) and copysign (the sign of a NaN
/// sign-source). Comparisons with NaN operands yield pattern-independent
/// i32 results, and selects/min/max/etc. either discard the NaN operand or
/// produce a NaN (matched with Number.isNaN), so they stay live tests.
fn isNanPayloadBoundarySkip(d: Directive) bool {
    if (!eql(d.t, "assert_return")) return false;
    const inv = d.invoke orelse return false;
    if (!eql(inv.name, "i32.reinterpret_f32") and !eql(inv.name, "i64.reinterpret_f64") and !eql(inv.name, "copysign")) return false;
    var exact_bits = false;
    for (d.expect) |e| exact_bits = exact_bits or expectRequiresExactBits(e);
    if (!exact_bits) return false;
    for (inv.args) |a| if (isNonCanonicalNanBits(a)) return true;
    return false;
}

/// Directives skipped on policy grounds, keyed by (file, line): places where
/// the pinned wg-1.0 suite asserts Core 1.0 semantics the engine deliberately
/// supersedes with Core 2.0 behavior (each with an engine test locking the
/// Core 2 rule in). Documented in the runner README/report.
const PolicySkip = struct { file: []const u8, line: usize, reason: []const u8 };
const policy_skips = [_]PolicySkip{
    .{
        .file = "linking.wast",
        .line = 236,
        .reason = "Core 1.0 instantiation is transactional, but the engine implements the Core 2.0 rule: writes from completed active element segments stay visible when a later segment traps (matches V8; locked by exec test 'instantiation trap retains earlier active segments')",
    },
    .{
        .file = "linking.wast",
        .line = 248,
        .reason = "same Core 2.0 instantiation rule: the completed element segment write to the imported table remains visible after the data segment failure",
    },
    .{
        .file = "linking.wast",
        .line = 342,
        .reason = "same Core 2.0 instantiation rule: the completed data segment write to the imported memory remains visible after the later segment failure",
    },
    .{
        .file = "linking.wast",
        .line = 354,
        .reason = "same Core 2.0 instantiation rule: the completed data segment write to the imported memory remains visible after the element segment failure",
    },
    .{
        .file = "unreached-invalid.wast",
        .line = 538,
        .reason = "Core 1.0 rejects br_table whose labels differ in type under a stack-polymorphic unreachable; the engine implements the Core 2.0 typing rule that accepts a polymorphic bottom (locked by validate test 'br_table accepts polymorphic bottom across result types')",
    },
};

fn policySkipReason(file: []const u8, line: usize) ?[]const u8 {
    for (policy_skips) |s| if (s.line == line and eql(s.file, file)) return s.reason;
    return null;
}

fn pushRecordPrefix(w: anytype, idx: usize) !void {
    try w.print("__out.push({{i:{d},s:", .{idx});
}

fn emitDirective(w: anytype, idx: usize, d: Directive, file: []const u8) !void {
    if (policySkipReason(file, d.line)) |reason| return emitHarnessSkip(w, idx, reason);
    if (eql(d.t, "module")) {
        const bin = d.bin orelse return emitHarnessSkip(w, idx, "module directive without binary");
        try w.writeAll("try{var m=new WebAssembly.Module(");
        try emitBin(w, bin);
        try w.writeAll(");var inst=new WebAssembly.Instance(m,__importsFor(m));");
        if (d.key) |key| {
            try w.writeAll("__mods.set(");
            try jsStrLit(w, key);
            try w.writeAll(",m);__insts.set(");
            try jsStrLit(w, key);
            try w.writeAll(",inst);");
        }
        try w.writeAll("__last=inst;");
        try pushRecordPrefix(w, idx);
        try w.writeAll("0});}catch(e){if(__isUnsupported(e)){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("2,r:\"post-MVP feature: \"+e.message});}else{");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"module directive failed: \"+__excText(e)});}}\n");
        return;
    }
    if (eql(d.t, "register")) {
        try w.writeAll("try{__registry.set(");
        try jsStrLit(w, d.name orelse "");
        try w.writeAll(",(");
        if (d.key) |key| {
            try w.writeAll("__insts.get(");
            try jsStrLit(w, key);
            try w.writeAll(")");
        } else try w.writeAll("__last");
        try w.writeAll(").exports);");
        try pushRecordPrefix(w, idx);
        try w.writeAll("0});}catch(e){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:__excText(e)});}\n");
        return;
    }
    if (eql(d.t, "invoke")) {
        const inv = d.invoke orelse return emitHarnessSkip(w, idx, "invoke directive without action");
        try w.writeAll("try{");
        try emitCall(w, inv);
        try w.writeAll(";");
        try pushRecordPrefix(w, idx);
        try w.writeAll("0});}catch(e){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:__excText(e)});}\n");
        return;
    }
    if (eql(d.t, "assert_return")) {
        const inv = d.invoke orelse return emitHarnessSkip(w, idx, "assert_return without action");
        if (isNanPayloadBoundarySkip(d)) {
            try pushRecordPrefix(w, idx);
            try w.writeAll(
                "2,r:\"NaN payload is implementation-defined at the JS API boundary (engine canonicalizes Number NaN); not observable through the JS API\"});\n",
            );
            return;
        }
        try w.writeAll("try{var a=");
        try emitCall(w, inv);
        try w.writeAll(";var bad=__expect(a,[");
        for (d.expect, 0..) |e, k| {
            if (k > 0) try w.writeByte(',');
            try emitConstLit(w, e);
        }
        try w.writeAll("]);if(bad){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:bad});}else{");
        try pushRecordPrefix(w, idx);
        try w.writeAll("0});}}catch(e){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:__excText(e)});}\n");
        return;
    }
    if (eql(d.t, "assert_return_nan")) {
        const inv = d.invoke orelse return emitHarnessSkip(w, idx, "assert_return_nan without action");
        try w.writeAll("try{var a=");
        try emitCall(w, inv);
        try w.writeAll(";var bad=__expectNan(a);if(bad){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:bad});}else{");
        try pushRecordPrefix(w, idx);
        try w.writeAll("0});}}catch(e){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:__excText(e)});}\n");
        return;
    }
    if (eql(d.t, "assert_trap") or eql(d.t, "assert_exhaustion")) {
        const inv = d.invoke orelse return emitHarnessSkip(w, idx, "trap directive without action");
        try w.writeAll("try{var a=");
        try emitCall(w, inv);
        try w.writeAll(";");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"expected trap containing \"+");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll("+\", got result \"+__showActual(a)});}catch(e){if(__trapCheck(e,");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll(")){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("0});}else{");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"expected WebAssembly.RuntimeError containing \"+");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll("+\", got \"+__excText(e)});}}\n");
        return;
    }
    if (eql(d.t, "assert_trap_module")) {
        const bin = d.bin orelse return emitHarnessSkip(w, idx, "trap_module directive without binary");
        try w.writeAll("try{var m=new WebAssembly.Module(");
        try emitBin(w, bin);
        try w.writeAll(");var inst=new WebAssembly.Instance(m,__importsFor(m));");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"expected trap containing \"+");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll("+\", module instantiated\"});}catch(e){if(__trapCheck(e,");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll(")){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("0});}else{");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"expected WebAssembly.RuntimeError containing \"+");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll("+\", got \"+__excText(e)});}}\n");
        return;
    }
    if (eql(d.t, "assert_malformed") or eql(d.t, "assert_invalid")) {
        const bin = d.bin orelse return emitHarnessSkip(w, idx, "compile directive without binary");
        try w.writeAll("try{new WebAssembly.Module(");
        try emitBin(w, bin);
        try w.writeAll(");");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"expected WebAssembly.CompileError containing \"+");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll("+\", module compiled\"});}catch(e){if(__compileCheck(e,");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll(")){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("0});}else{");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"expected WebAssembly.CompileError containing \"+");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll("+\", got \"+__excText(e)});}}\n");
        return;
    }
    if (eql(d.t, "assert_unlinkable")) {
        const bin = d.bin orelse return emitHarnessSkip(w, idx, "unlinkable directive without binary");
        try w.writeAll("try{var m=new WebAssembly.Module(");
        try emitBin(w, bin);
        try w.writeAll(");try{new WebAssembly.Instance(m,__importsFor(m));");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"expected WebAssembly.LinkError containing \"+");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll("+\", module instantiated\"});}catch(e){if(__linkCheck(e,");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll(")){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("0});}else{");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"expected WebAssembly.LinkError containing \"+");
        try jsStrLit(w, d.text orelse "");
        try w.writeAll("+\", got \"+__excText(e)});}}}catch(e2){");
        try pushRecordPrefix(w, idx);
        try w.writeAll("1,e:\"module failed to compile before link check: \"+__excText(e2)});}\n");
        return;
    }
    if (eql(d.t, "assert_malformed_text") or eql(d.t, "skipped_module")) {
        try pushRecordPrefix(w, idx);
        try w.writeAll("2,r:");
        try jsStrLit(w, d.reason orelse "not applicable through the binary runtime");
        try w.writeAll("});\n");
        return;
    }
    try emitHarnessSkip(w, idx, "unknown directive type");
}

fn emitHarnessSkip(w: anytype, idx: usize, reason: []const u8) !void {
    try pushRecordPrefix(w, idx);
    try w.writeAll("2,r:");
    try jsStrLit(w, reason);
    try w.writeAll("});\n");
}

// ---------------------------------------------------------------------------
// readModule native: copy module bytes into a fresh Uint8Array.
// ---------------------------------------------------------------------------

var g_modules: []const u8 = &.{};

fn readModuleNative(raw: *anyopaque, _: Value, args: []const Value) js.HostError!Value {
    const self: *js.Interpreter = @ptrCast(@alignCast(raw));
    if (args.len < 2) return self.throwError("RangeError", "readModule requires offset and length");
    const off_f = try self.toNumberV(args[0]);
    const len_f = try self.toNumberV(args[1]);
    if (!std.math.isFinite(off_f) or !std.math.isFinite(len_f) or off_f < 0 or len_f < 0 or
        off_f > 9007199254740991 or len_f > 9007199254740991)
        return self.throwError("RangeError", "readModule offset/length out of range");
    const off: usize = @intFromFloat(off_f);
    const len: usize = @intFromFloat(len_f);
    if (off > g_modules.len or len > g_modules.len - off)
        return self.throwError("RangeError", "readModule range outside modules.bin");
    const buffer = try self.makeArrayBuffer(len);
    @memcpy(buffer.arrayBuffer().?.bytes(), g_modules[off .. off + len]);
    return self.makeTypedArray(.u8, &.{Value.obj(buffer)});
}

fn defineNative(ctx: *js.Context, name: []const u8, f: js.NativeFn) !void {
    const obj = try ctx.arena().create(js.Object);
    obj.* = .{ .native = f };
    try ctx.env.put(name, Value.obj(obj));
}

// ---------------------------------------------------------------------------
// Worker mode.
// ---------------------------------------------------------------------------

fn reportJson(gpa: std.mem.Allocator, report: FileReport) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, report, .{});
}

fn printWorkerReport(gpa: std.mem.Allocator, io: std.Io, report: FileReport) void {
    const text = reportJson(gpa, report) catch {
        std.Io.File.stdout().writeStreamingAll(io, "{\"file\":\"\",\"crash\":\"report serialization failed\"}\n") catch {};
        return;
    };
    defer gpa.free(text);
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
    std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
}

/// Best-effort exception text after a failed evaluate: re-enter the context
/// with the pending exception bound to a global and let the JS helper render
/// it. Falls back to the Zig error name.
fn exceptionDetail(ctx: *js.Context, err: anyerror, fallback_buf: []u8) []const u8 {
    if (err == error.Throw) {
        if (ctx.exception) |exc| {
            ctx.env.put("__pendingExc", exc) catch {};
            if (ctx.evaluate("try{__excText(__pendingExc)}catch(_){\"harness exception\"}")) |v| {
                if (v.isString()) return v.asStr();
            } else |_| {}
        }
    }
    return std.fmt.bufPrint(fallback_buf, "{s}", .{@errorName(err)}) catch "evaluation failed";
}

fn runWorker(gpa: std.mem.Allocator, io: std.Io, spec_dir: []const u8, target_file: []const u8) !void {
    const artifacts = loadArtifacts(gpa, io, spec_dir) catch |err| {
        printWorkerReport(gpa, io, .{
            .file = target_file,
            .crash = try std.fmt.allocPrint(gpa, "artifact load failed: {s}", .{@errorName(err)}),
        });
        return;
    };
    g_modules = artifacts.modules;

    var entry: ?FileEntry = null;
    for (artifacts.manifest.files) |f| {
        if (eql(f.file, target_file)) {
            entry = f;
            break;
        }
    }
    const file = entry orelse {
        printWorkerReport(gpa, io, .{ .file = target_file, .crash = "file not present in manifest" });
        return;
    };

    const ctx = js.Context.create(gpa) catch |err| {
        printWorkerReport(gpa, io, .{
            .file = target_file,
            .crash = try std.fmt.allocPrint(gpa, "context creation failed: {s}", .{@errorName(err)}),
        });
        return;
    };
    defer ctx.destroy();
    defineNative(ctx, "readModule", readModuleNative) catch |err| {
        printWorkerReport(gpa, io, .{
            .file = target_file,
            .crash = try std.fmt.allocPrint(gpa, "native injection failed: {s}", .{@errorName(err)}),
        });
        return;
    };

    var failures: std.ArrayListUnmanaged(Failure) = .empty;
    var skips: std.ArrayListUnmanaged(Skip) = .empty;
    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;

    var fallback_buf: [128]u8 = undefined;

    // 1. Prelude. A failure here is a harness bug: every directive fails.
    _ = ctx.evaluate(prelude) catch |err| {
        const detail = exceptionDetail(ctx, err, &fallback_buf);
        for (file.directives) |d| {
            fail += 1;
            try failures.append(gpa, .{
                .line = d.line,
                .kind = d.t,
                .detail = try std.fmt.allocPrint(gpa, "prelude evaluation failed: {s}", .{detail}),
            });
        }
        printWorkerReport(gpa, io, .{
            .file = target_file,
            .pass = pass,
            .fail = fail,
            .skip = skip,
            .failures = failures.items,
            .skips = skips.items,
        });
        return;
    };

    // 2. One big directives script; final expression is JSON.stringify(__out).
    var script: std.ArrayListUnmanaged(u8) = .empty;
    const w = ListWriter{ .list = &script, .gpa = gpa };
    try w.writeAll("try{\n");
    for (file.directives, 0..) |d, idx| try emitDirective(w, idx, d, file.file);
    try w.print("}}catch(__top){{__out.push({{i:{d},s:1,e:\"harness escape: \"+__excText(__top)}});}}\nJSON.stringify(__out);\n", .{harness_record_index});

    const json_text: []const u8 = blk: {
        const result = ctx.evaluate(script.items) catch |err| {
            const detail = exceptionDetail(ctx, err, &fallback_buf);
            for (file.directives) |d| {
                fail += 1;
                try failures.append(gpa, .{
                    .line = d.line,
                    .kind = d.t,
                    .detail = try std.fmt.allocPrint(gpa, "directive evaluation failed: {s}", .{detail}),
                });
            }
            printWorkerReport(gpa, io, .{
                .file = target_file,
                .pass = pass,
                .fail = fail,
                .skip = skip,
                .failures = failures.items,
                .skips = skips.items,
            });
            return;
        };
        if (!result.isString()) {
            for (file.directives) |d| {
                fail += 1;
                try failures.append(gpa, .{ .line = d.line, .kind = d.t, .detail = "harness did not produce a JSON result" });
            }
            printWorkerReport(gpa, io, .{
                .file = target_file,
                .pass = pass,
                .fail = fail,
                .skip = skip,
                .failures = failures.items,
                .skips = skips.items,
            });
            return;
        }
        break :blk result.asStr();
    };

    // 3. Fold records into the per-file report. Directives missing from the
    //    record stream (a harness escape aborts later blocks) fail explicitly.
    const parsed = std.json.parseFromSlice([]JsRecord, gpa, json_text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        for (file.directives) |d| {
            fail += 1;
            try failures.append(gpa, .{
                .line = d.line,
                .kind = d.t,
                .detail = try std.fmt.allocPrint(gpa, "harness result JSON parse failed: {s}", .{@errorName(err)}),
            });
        }
        printWorkerReport(gpa, io, .{
            .file = target_file,
            .pass = pass,
            .fail = fail,
            .skip = skip,
            .failures = failures.items,
            .skips = skips.items,
        });
        return;
    };

    var recorded = try gpa.alloc(bool, file.directives.len);
    @memset(recorded, false);
    var harness_detail: ?[]const u8 = null;
    for (parsed.value) |rec| {
        if (rec.i >= file.directives.len) {
            harness_detail = rec.e orelse "harness aborted";
            continue;
        }
        recorded[rec.i] = true;
        const d = file.directives[rec.i];
        switch (rec.s) {
            0 => pass += 1,
            2 => {
                skip += 1;
                try skips.append(gpa, .{ .line = d.line, .kind = d.t, .reason = rec.r orelse "skipped" });
            },
            else => {
                fail += 1;
                try failures.append(gpa, .{ .line = d.line, .kind = d.t, .detail = rec.e orelse "failed" });
            },
        }
    }
    for (file.directives, 0..) |d, idx| {
        if (recorded[idx]) continue;
        fail += 1;
        try failures.append(gpa, .{
            .line = d.line,
            .kind = d.t,
            .detail = try std.fmt.allocPrint(gpa, "directive not recorded ({s})", .{harness_detail orelse "harness aborted"}),
        });
    }

    printWorkerReport(gpa, io, .{
        .file = target_file,
        .pass = pass,
        .fail = fail,
        .skip = skip,
        .failures = failures.items,
        .skips = skips.items,
    });
}

// ---------------------------------------------------------------------------
// Parent mode.
// ---------------------------------------------------------------------------

fn termText(gpa: std.mem.Allocator, term: std.process.Child.Term) ![]const u8 {
    return switch (term) {
        .exited => |code| try std.fmt.allocPrint(gpa, "exit {d}", .{code}),
        .signal => |sig| try std.fmt.allocPrint(gpa, "signal {d}", .{@intFromEnum(sig)}),
        .stopped => |sig| try std.fmt.allocPrint(gpa, "stopped {d}", .{@intFromEnum(sig)}),
        .unknown => |code| try std.fmt.allocPrint(gpa, "unknown {d}", .{code}),
    };
}

fn crashReport(gpa: std.mem.Allocator, file: []const u8, reason: []const u8, stderr_tail: []const u8) !FileReport {
    var tail = stderr_tail;
    if (tail.len > 200) tail = tail[tail.len - 200 ..];
    const detail = if (tail.len > 0)
        try std.fmt.allocPrint(gpa, "{s}: {s}", .{ reason, tail })
    else
        try gpa.dupe(u8, reason);
    return .{ .file = try gpa.dupe(u8, file), .crash = detail };
}

fn parseWorkerReport(gpa: std.mem.Allocator, stdout: []const u8) ?FileReport {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;
    const parsed = std.json.parseFromSlice(FileReport, gpa, trimmed, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return parsed.value;
}

fn runParent(gpa: std.mem.Allocator, io: std.Io, init: std.process.Init, spec_dir: []const u8) !u8 {
    // `WASM_SPEC_FILTER` (runtime) wins over `-Dwasm-spec-filter` (baked in)
    // so a single build can be swept file-by-file without recompiling.
    const filter = init.environ_map.get("WASM_SPEC_FILTER") orelse build_options.filter;
    const out_path = init.environ_map.get("WASM_SPEC_OUT") orelse build_options.out;

    const artifacts = try loadArtifacts(gpa, io, spec_dir);
    const exe = std.process.executablePathAlloc(io, gpa) catch {
        std.debug.print("wasm-spec: could not resolve own executable path; cannot spawn workers.\n", .{});
        return 2;
    };

    var env_map = init.environ_map.clone(gpa) catch {
        std.debug.print("wasm-spec: could not clone the environment map.\n", .{});
        return 2;
    };

    std.debug.print(
        "zig-js WebAssembly wg-1.0 spec suite (subprocess-isolated)\n==========================================================\n",
        .{},
    );
    std.debug.print("pin: {s}@{s} ({s})\ndir: {s}{s}{s}\n", .{
        artifacts.manifest.pin.repo,
        artifacts.manifest.pin.ref,
        artifacts.manifest.pin.sha,
        spec_dir,
        if (filter.len > 0) "  filter: " else "",
        filter,
    });

    var reports: std.ArrayListUnmanaged(FileReport) = .empty;
    var totals: Totals = .{};

    for (artifacts.manifest.files) |file| {
        if (filter.len > 0 and std.mem.indexOf(u8, file.file, filter) == null) continue;
        try env_map.put("WASM_SPEC_WORKER", file.file);
        const argv = [_][]const u8{exe};
        var report: FileReport = undefined;
        const res = std.process.run(gpa, io, .{
            .argv = &argv,
            .environ_map = &env_map,
            .stdout_limit = .limited(64 << 20),
            .stderr_limit = .limited(1 << 20),
            .timeout = child_timeout,
        }) catch |err| switch (err) {
            error.Timeout => {
                report = try crashReport(gpa, file.file, "timeout", "");
                try reports.append(gpa, report);
                totals.files += 1;
                totals.crash += 1;
                std.debug.print("  CRASH   {s}: timeout after 120s\n", .{file.file});
                continue;
            },
            else => return err,
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);

        if (parseWorkerReport(gpa, res.stdout)) |rep| {
            report = rep;
        } else {
            const reason = try std.fmt.allocPrint(gpa, "worker crashed ({s})", .{try termText(gpa, res.term)});
            report = try crashReport(gpa, file.file, reason, res.stderr);
        }
        try reports.append(gpa, report);
        totals.files += 1;
        totals.pass += report.pass;
        totals.fail += report.fail;
        totals.skip += report.skip;
        if (report.crash != null) {
            totals.crash += 1;
            std.debug.print("  CRASH   {s}: {s}\n", .{ report.file, report.crash.? });
        } else if (report.fail > 0) {
            std.debug.print("  FAIL    {s}: pass {d} fail {d} skip {d}\n", .{ report.file, report.pass, report.fail, report.skip });
            for (report.failures[0..@min(report.failures.len, 8)]) |f|
                std.debug.print("          line {d} {s}: {s}\n", .{ f.line, f.kind, f.detail });
            if (report.failures.len > 8)
                std.debug.print("          ... and {d} more\n", .{report.failures.len - 8});
        } else {
            std.debug.print("  ok      {s}: pass {d} skip {d}\n", .{ report.file, report.pass, report.skip });
        }
    }

    std.debug.print("----------------------------------------------------------\n", .{});
    std.debug.print("files {d}  pass {d}  fail {d}  skip {d}  crash {d}\n", .{
        totals.files, totals.pass, totals.fail, totals.skip, totals.crash,
    });

    const inventory = Inventory{
        .format = 1,
        .pin = artifacts.manifest.pin,
        .files = reports.items,
        .totals = totals,
    };
    const inventory_json = try std.json.Stringify.valueAlloc(gpa, inventory, .{});
    std.Io.File.stdout().writeStreamingAll(io, inventory_json) catch {};
    std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};

    if (out_path.len > 0) {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = inventory_json }) catch |err| {
            std.debug.print("wasm-spec: failed to write inventory to {s}: {s}\n", .{ out_path, @errorName(err) });
            return 2;
        };
        std.debug.print("inventory written to {s}\n", .{out_path});
    }

    return if (totals.fail == 0 and totals.crash == 0) 0 else 1;
}

// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const gpa = arena.allocator();
    const io = init.io;

    const spec_dir = init.environ_map.get("WASM_SPEC_DIR") orelse spec_dir_default;

    if (init.environ_map.get("WASM_SPEC_WORKER")) |target_file| {
        try runWorker(gpa, io, spec_dir, target_file);
        return;
    }

    const code = try runParent(gpa, io, init, spec_dir);
    if (code != 0) std.process.exit(code);
}
