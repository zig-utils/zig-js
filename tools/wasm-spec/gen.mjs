#!/usr/bin/env bun
//! tools/wasm-spec-gen.mjs — convert the pinned upstream WebAssembly spec
//! testsuite (wg-1.0, pure MVP) into the packed artifacts consumed by
//! conformance/wasm_spec.zig.
//!
//! Usage:
//!   bun tools/wasm-spec-gen.mjs <spec-test-core-dir> <out-dir>
//!
//! Inputs : <spec-test-core-dir>/*.wast  (from WebAssembly/spec at the pin
//!          recorded in the manifest; fetch with tools/wasm-spec-fetch.sh)
//! Outputs: <out-dir>/manifest.json      (directives with binary offsets)
//!          <out-dir>/modules.bin        (concatenated wasm binaries)
//!
//! `wabt` (npm, Emscripten build) is used exactly once per module to turn
//! WebAssembly text into binary; every semantic decision (which directive,
//! which bytes, which expected value) is made here and recorded in the
//! manifest, so the Zig runner needs no text tooling at all.

import { readdirSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, basename } from "node:path";
import wabtInit from "wabt";

const PIN = {
  repo: "WebAssembly/spec",
  ref: "wg-1.0",
  sha: "977f97014c962f7bd1291fcc6d28b41a924882bf",
};

// ---------------------------------------------------------------- s-expressions

// Tokenize .wast into s-expr ASTs with 1-based line numbers.
function parseScript(src, file) {
  let i = 0, line = 1;
  const n = src.length;
  const err = (msg) => new Error(`${file}:${line}: ${msg}`);

  function skipTrivia() {
    for (;;) {
      while (i < n && (src[i] === " " || src[i] === "\t" || src[i] === "\r" || src[i] === "\n")) {
        if (src[i] === "\n") line++;
        i++;
      }
      if (src[i] === ";" && src[i + 1] === ";") {
        while (i < n && src[i] !== "\n") i++;
        continue;
      }
      if (src[i] === "(" && src[i + 1] === ";") {
        let depth = 1;
        i += 2;
        while (i < n && depth > 0) {
          if (src[i] === "\n") line++;
          if (src[i] === "(" && src[i + 1] === ";") { depth++; i += 2; }
          else if (src[i] === ";" && src[i + 1] === ")") { depth--; i += 2; }
          else i++;
        }
        if (depth !== 0) throw err("unterminated block comment");
        continue;
      }
      return;
    }
  }

  function parseString() {
    const startLine = line;
    i++; // opening quote
    let raw = "";
    while (i < n && src[i] !== '"') {
      if (src[i] === "\n") throw err("newline in string");
      if (src[i] === "\\") {
        const c = src[i + 1];
        if (c === "n" || c === "t" || c === "\\" || c === '"' || c === "'") {
          raw += src.slice(i, i + 2); i += 2;
        } else if (/[0-9a-fA-F]/.test(c)) {
          raw += src.slice(i, i + 3); i += 3;
        } else throw err(`bad string escape \\${c}`);
      } else {
        raw += src[i++];
      }
    }
    if (i >= n) throw err("unterminated string");
    i++;
    return { str: raw, line: startLine };
  }

  function parseAtom() {
    const startLine = line;
    let s = "";
    while (i < n && !"() \t\r\n;".includes(src[i])) s += src[i++];
    // A ';' directly after an atom starts a line comment only if ';;'.
    return { atom: s, line: startLine };
  }

  function parseNode() {
    skipTrivia();
    if (i >= n) return null;
    if (src[i] === "(") {
      const startLine = line;
      i++;
      const items = [];
      for (;;) {
        skipTrivia();
        if (i >= n) throw err("unterminated list");
        if (src[i] === ")") { i++; return { list: items, line: startLine }; }
        items.push(parseNode());
      }
    }
    if (src[i] === '"') return parseString();
    return parseAtom();
  }

  const top = [];
  for (;;) {
    const node = parseNode();
    if (node === null) return top;
    top.push(node);
  }
}

// Decode a wast string literal body (escape sequences) into bytes. The
// source file is read as latin1, so each char IS one byte (0-255); this
// preserves non-UTF-8 payloads exactly.
function decodeWastString(raw) {
  const out = [];
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (c !== "\\") {
      out.push(c.charCodeAt(0) & 0xff);
      continue;
    }
    const e = raw[++i];
    if (e === "n") out.push(0x0a);
    else if (e === "t") out.push(0x09);
    else if (e === "\\") out.push(0x5c);
    else if (e === '"') out.push(0x22);
    else if (e === "'") out.push(0x27);
    else out.push(parseInt(e + raw[++i], 16));
  }
  return Buffer.from(out);
}

// Print an s-expr AST back to wat source (strings re-escaped as bytes).
// elem/data nodes are normalized to canonical MVP form: the pinned suite
// exercises intermediate-era text syntax ((elem $t ...), (elem 0 ...),
// (elem (offset ...) ...), (data $m ...), ...) that current wabt rejects;
// the table/memory use is always the MVP index space 0, so dropping it and
// unwrapping (offset ...) yields identical binary semantics.
function printWat(node) {
  if (node.atom !== undefined) return node.atom;
  if (node.str !== undefined) {
    const bytes = decodeWastString(node.str);
    let s = '"';
    for (const b of bytes) {
      if (b >= 0x20 && b < 0x7f && b !== 0x22 && b !== 0x5c) s += String.fromCharCode(b);
      else s += "\\" + b.toString(16).padStart(2, "0");
    }
    return s + '"';
  }
  const head = node.list[0] && node.list[0].atom;
  if (head === "elem" || head === "data") {
    let rest = node.list.slice(1);
    // Only an ACTIVE segment (one containing an offset expression, as
    // "(offset ...)" or a bare instruction) may carry a leading table/memory
    // use to drop. The (table (elem $f ...)) / (memory (data ...)) sugar has
    // no offset — every item is a func index or string and must be kept, even
    // when the first one happens to be "$"-named or numeric.
    const isActive = rest.some((n) => n.list !== undefined);
    if (isActive) {
      // Drop a leading table/memory use: $name, decimal, or hex index.
      if (rest.length && rest[0].atom !== undefined && /^(\$|0x|\d)/.test(rest[0].atom)) rest = rest.slice(1);
      // Drop a (table $t) / (memory $m) wrapper if present.
      if (rest.length && rest[0].list && /^(table|memory)$/.test(rest[0].list[0]?.atom ?? "")) rest = rest.slice(1);
    }
    let out = [];
    if (rest.length && rest[0].list && rest[0].list[0]?.atom === "offset") {
      out.push(rest[0].list.slice(1).map(printWat).join(" "));
      rest = rest.slice(1);
    }
    out = out.concat(rest.map(printWat));
    return "(" + head + " " + out.join(" ") + ")";
  }
  return "(" + node.list.map(printWat).join(" ") + ")";
}

// ---------------------------------------------------------------- wast numbers

// Exact rational -> binary float rounding (roundTiesToEven), used for both
// decimal and hexadecimal literals so expected f32/f64 bit patterns are
// exact regardless of double-rounding hazards.
// value = mantissa * 2^exp (mantissa >= 0, BigInt) -> { bits } at `prec` bits.
function roundRational(mantissa, exp, prec, bitsTotal) {
  if (mantissa === 0n) return 0n;
  const expBits = bitsTotal === 32 ? 8 : 11;
  const bias = (1n << BigInt(expBits - 1)) - 1n;
  const maxExp = (1n << BigInt(expBits)) - 1n; // biased, inf/nan field
  const fracBits = BigInt(prec - 1);

  // Unbiased exponent of the leading significand bit: 2^E <= value < 2^(E+1).
  const mBits = BigInt(mantissa.toString(2).length);
  const leadExp = mBits - 1n + exp;

  // Below the smallest normal exponent (2^(1-bias)) the exponent field is
  // zero and the significand is the (possibly zero) subnormal fraction.
  const minNormalExp = 1n - bias;
  const subnormal = leadExp < minNormalExp;

  // Scale so one significand unit is 2^sigExp, then round to the nearest
  // integer (ties to even). Normal values get a prec-bit significand;
  // subnormals an integer fraction.
  const sigExp = (subnormal ? minNormalExp : leadExp) - fracBits;
  const shift = exp - sigExp;
  let sig;
  if (shift >= 0n) {
    sig = mantissa << shift;
  } else {
    const r = -shift;
    const kept = mantissa >> r;
    const dropped = mantissa & ((1n << r) - 1n);
    const half = 1n << (r - 1n);
    sig = kept;
    if (dropped > half || (dropped === half && (kept & 1n) === 1n)) sig += 1n;
  }

  if (subnormal) {
    if (sig >> fracBits !== 0n) return 1n << fracBits; // rounded up to the smallest normal
    return sig;
  }

  // A carry out of the top significand bit (1.11..1 rounded up) renormalizes
  // to 10.0..0 with the exponent bumped; that bump may overflow to infinity.
  let biased = leadExp + bias;
  if (sig >> fracBits >= 2n) {
    sig >>= 1n;
    biased += 1n;
  }
  if (biased >= maxExp) return BigInt(maxExp) << fracBits; // overflow to infinity
  return (BigInt(biased) << fracBits) | (sig & ((1n << fracBits) - 1n));
}

function parseWastInt(s) {
  const clean = s.replaceAll("_", "");
  let neg = false;
  let body = clean;
  if (body.startsWith("-")) { neg = true; body = body.slice(1); }
  else if (body.startsWith("+")) body = body.slice(1);
  let v;
  if (body.startsWith("0x") || body.startsWith("0X")) v = BigInt(body);
  else v = BigInt(body);
  return neg ? -v : v;
}

function toUnsignedDec(v, bits) {
  const mod = 1n << BigInt(bits);
  return ((v % mod) + mod).toString();
}

// Parse a wast float literal to exact bits for f32/f64.
// Returns { kind: "bits", bits: "<unsigned decimal>" } or
//         { kind: "nan_canonical" } or { kind: "nan_arithmetic" }.
function parseWastFloat(s, prec, bitsTotal) {
  const fracBits = BigInt(prec - 1);
  let neg = false;
  let body = s.replaceAll("_", "");
  if (body.startsWith("-")) { neg = true; body = body.slice(1); }
  else if (body.startsWith("+")) body = body.slice(1);
  const signBit = neg ? (1n << BigInt(bitsTotal - 1)) : 0n;

  if (body === "inf") return { kind: "bits", bits: (signBit | (((1n << BigInt(bitsTotal === 32 ? 8 : 11)) - 1n) << fracBits)).toString() };
  if (body === "nan") {
    // Positive quiet NaN with the canonical payload.
    const exp = (1n << BigInt(bitsTotal === 32 ? 8 : 11)) - 1n;
    return { kind: "bits", bits: (signBit | (exp << fracBits) | (1n << (fracBits - 1n))).toString() };
  }
  if (body === "nan:canonical") return { kind: "nan_canonical" };
  if (body === "nan:arithmetic") return { kind: "nan_arithmetic" };
  if (body.startsWith("nan:0x")) {
    const payload = BigInt(body.slice(4));
    const exp = (1n << BigInt(bitsTotal === 32 ? 8 : 11)) - 1n;
    return { kind: "bits", bits: (signBit | (exp << fracBits) | payload).toString() };
  }

  // Numeric literal: hex or decimal, exact rational.
  let mantissa, exp2;
  if (body.startsWith("0x")) {
    const m = /^0x([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?\d+))?$/.exec(body);
    if (!m) throw new Error(`bad hex float: ${s}`);
    const intDigits = m[1] || "0";
    const fracDigits = m[2] || "";
    mantissa = BigInt("0x" + ((intDigits === "" ? "0" : intDigits) + fracDigits) || "0x0");
    exp2 = BigInt(m[3] || "0") - BigInt(4 * fracDigits.length);
  } else {
    const m = /^(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$/.exec(body);
    if (!m) throw new Error(`bad decimal float: ${s}`);
    const intDigits = m[1] || "0";
    const fracDigits = m[2] || "";
    const digits = (intDigits + fracDigits).replace(/^0+(?=\d)/, "");
    mantissa = BigInt(digits === "" ? "0" : digits);
    const exp10 = BigInt(m[3] || "0") - BigInt(fracDigits.length);
    // mantissa * 10^exp10 -> exact binary rational
    if (exp10 >= 0n) {
      mantissa = mantissa * (5n ** exp10);
      exp2 = exp10;
    } else {
      // mantissa / 10^k = mantissa / (2^k 5^k): keep exact by scaling up.
      const k = -exp10;
      const f = 5n ** k;
      // floor(mantissa * 2^extra / 5^k) approximates value * 2^(extra + k),
      // so exp2 = -(extra + k) restores the value. The shift must also
      // outgrow the 5^k divisor (5^k < 2^(7k/3)): with a fixed shift a tiny
      // value like 99e-123 underflows to zero long before roundRational can
      // see any significant bits. extra >= bitsTotal*4 + 7k/3 keeps at least
      // bitsTotal*4 significant bits for any mantissa >= 1.
      const extra = BigInt(bitsTotal * 4) + 3n * k;
      mantissa = (mantissa << extra) / f;
      exp2 = -(extra + k);
    }
  }
  const bits = roundRational(mantissa, exp2, prec, bitsTotal);
  return { kind: "bits", bits: (signBit | bits).toString() };
}

function parseConst(node, file) {
  // (i32.const N) / (i64.const N) / (f32.const X) / (f64.const X)
  if (node.list === undefined || node.list.length !== 2) throw new Error(`${file}:${node.line}: bad const`);
  const head = node.list[0].atom;
  const lit = node.list[1].atom;
  switch (head) {
    case "i32.const": return { t: "i32", v: toUnsignedDec(parseWastInt(lit), 32) };
    case "i64.const": return { t: "i64", v: toUnsignedDec(parseWastInt(lit), 64) };
    case "f32.const": return { t: "f32", ...parseWastFloat(lit, 24, 32) };
    case "f64.const": return { t: "f64", ...parseWastFloat(lit, 53, 64) };
    default: throw new Error(`${file}:${node.line}: unsupported const ${head}`);
  }
}

// ---------------------------------------------------------------- directives

function atomOf(node) { return node && node.atom; }

function parseInvoke(node, file) {
  // (invoke $name? "field" (const)*) | (get $name? "field") — `get` reads an
  // exported global and only appears inside assert_return.
  if (node.list === undefined) throw new Error(`${file}:${node.line}: bad invoke`);
  const head = atomOf(node.list[0]);
  if (head !== "invoke" && head !== "get") throw new Error(`${file}:${node.line}: bad invoke`);
  let idx = 1;
  let key = null;
  if (node.list[idx] && node.list[idx].atom && node.list[idx].atom.startsWith("$")) key = node.list[idx++].atom;
  const fieldNode = node.list[idx++];
  if (!fieldNode || fieldNode.str === undefined) throw new Error(`${file}:${node.line}: ${head} needs a field name`);
  const name = Buffer.from(decodeWastString(fieldNode.str)).toString("utf8");
  const args = node.list.slice(idx).map((c) => parseConst(c, file));
  return { kind: head, key, name, args };
}

// ---------------------------------------------------------------- main

async function main() {
  const [srcDir, outDir] = process.argv.slice(2);
  if (!srcDir || !outDir) {
    console.error("usage: bun tools/wasm-spec-gen.mjs <spec-test-core-dir> <out-dir>");
    process.exit(2);
  }
  const wabt = await wabtInit();
  mkdirSync(outDir, { recursive: true });

  const files = readdirSync(srcDir).filter((f) => f.endsWith(".wast")).sort();
  const manifest = { format: 1, pin: PIN, modules_bin: "modules.bin", files: [] };
  const binParts = [];
  let binOffset = 0;
  let stats = { modules: 0, asserts: 0, malformed_text: 0, gen_skips: 0 };

  function pushBin(bytes) {
    const off = binOffset;
    binParts.push(bytes);
    binOffset += bytes.length;
    return [off, bytes.length];
  }

  // Compile a module node to bytes, or throw a tagged error.
  function moduleBytes(node, file) {
    // node is the inner list of the (module ...) form's tail handling.
    const items = node.list;
    let idx = 1;
    let key = null;
    if (items[idx] && items[idx].atom && items[idx].atom.startsWith("$")) key = items[idx++].atom;
    let rest = items.slice(idx);
    // (module binary "...") / (module quote "...") forms: binary/quote are
    // bare keyword atoms directly inside the module form.
    if (rest.length >= 1 && rest[0].atom !== undefined && (rest[0].atom === "binary" || rest[0].atom === "quote")) {
      const kind = rest[0].atom;
      const parts = rest.slice(1).map((s) => {
        if (s.str === undefined) throw new Error(`${file}:${s.line}: ${kind} needs strings`);
        return decodeWastString(s.str);
      });
      if (kind === "binary") return { key, bytes: Buffer.concat(parts), wasText: false };
      const watText = Buffer.concat(parts).toString("utf8");
      const m = wabt.parseWat(file, watText, { features: {} });
      m.resolveNames();
      return { key, bytes: Buffer.from(m.toBinary({ no_check: true }).buffer), wasText: true };
    }
    const wat = "(" + rest.map((n) => printWat(n)).join(" ") + ")";
    const full = "(module " + wat.slice(1);
    let m;
    try {
      m = wabt.parseWat(file, full, { features: {} });
      m.resolveNames();
    } catch (e) {
      throw new Error(`${file}:${node.line}: parseWat failed (${e.message.split("\n")[1]?.trim() ?? e.message}) in generated wat: ${full.slice(0, 160)}`);
    }
    return { key, bytes: Buffer.from(m.toBinary({ no_check: true }).buffer), wasText: true };
  }

  for (const file of files) {
    const src = readFileSync(join(srcDir, file), "latin1");
    let script = parseScript(src, file);
    // "Inline module" format (inline-module.wast): bare top-level fields
    // with no directives are equivalent to one anonymous (module ...).
    const DIRECTIVES = new Set(["module", "register", "invoke", "assert_return", "assert_trap", "assert_exhaustion", "assert_malformed", "assert_invalid", "assert_unlinkable", "assert_return_canonical_nan", "assert_return_arithmetic_nan"]);
    if (script.length > 0 && !DIRECTIVES.has(atomOf(script[0].list?.[0]))) {
      script = [{ list: [{ atom: "module", line: 1 }, ...script], line: 1 }];
    }
    const directives = [];
    let anonCounter = 0;

    for (const d of script) {
      if (d.list === undefined) throw new Error(`${file}:${d.line}: top-level atom`);
      const head = atomOf(d.list[0]);
      const line = d.line;

      if (head === "module") {
        let mod;
        try {
          mod = moduleBytes(d, file);
        } catch (e) {
          throw new Error(`${file}:${line}: generator could not compile a required module: ${e.message}`);
        }
        const key = mod.key ?? `$m${anonCounter++}`;
        directives.push({ t: "module", line, key, bin: pushBin(mod.bytes) });
        stats.modules++;
        continue;
      }

      if (head === "register") {
        // (register "name" $mod?)
        const name = Buffer.from(decodeWastString(d.list[1].str)).toString("utf8");
        const key = d.list[2] ? d.list[2].atom : null;
        directives.push({ t: "register", line, name, key });
        continue;
      }

      if (head === "invoke") {
        directives.push({ t: "invoke", line, invoke: parseInvoke(d, file) });
        stats.asserts++;
        continue;
      }

      if (head === "assert_return") {
        const invoke = parseInvoke(d.list[1], file);
        const expect = d.list.slice(2).map((c) => parseConst(c, file));
        directives.push({ t: "assert_return", line, invoke, expect });
        stats.asserts++;
        continue;
      }

      if (head === "assert_return_canonical_nan" || head === "assert_return_arithmetic_nan") {
        // JS Numbers collapse NaN payloads at the API boundary, so through
        // the JS API these are observable as "result is NaN" (payload
        // exactness is still covered bit-for-bit via i32/i64.reinterpret
        // assertions in the suite).
        const invoke = parseInvoke(d.list[1], file);
        directives.push({ t: "assert_return_nan", line, invoke, nan: head === "assert_return_canonical_nan" ? "canonical" : "arithmetic" });
        stats.asserts++;
        continue;
      }

      if (head === "assert_trap" || head === "assert_exhaustion") {
        const inner = d.list[1];
        const text = d.list[2] && d.list[2].str !== undefined
          ? Buffer.from(decodeWastString(d.list[2].str)).toString("utf8") : "";
        if (inner.list && atomOf(inner.list[0]) === "invoke") {
          directives.push({ t: head, line, invoke: parseInvoke(inner, file), text });
        } else if (inner.list && atomOf(inner.list[0]) === "module") {
          try {
            const mod = moduleBytes(inner, file);
            directives.push({ t: "assert_trap_module", line, bin: pushBin(mod.bytes), text });
            stats.modules++;
          } catch (e) {
            directives.push({ t: "skipped_module", line, directive: head, text, reason: `generator: ${String(e.message).slice(0, 120)}` });
            stats.gen_skips++;
          }
        } else {
          throw new Error(`${file}:${line}: unsupported ${head} payload`);
        }
        stats.asserts++;
        continue;
      }

      if (head === "assert_malformed") {
        const inner = d.list[1];
        const text = d.list[2] && d.list[2].str !== undefined
          ? Buffer.from(decodeWastString(d.list[2].str)).toString("utf8") : "";
        if (!inner.list || atomOf(inner.list[0]) !== "module") throw new Error(`${file}:${line}: unsupported assert_malformed payload`);
        const isQuote = inner.list.some((x) => x.atom === "quote");
        try {
          const mod = moduleBytes(inner, file);
          if (isQuote) {
            // wabt accepted text the suite calls malformed — still test the bytes.
            directives.push({ t: "assert_malformed", line, bin: pushBin(mod.bytes), text });
            stats.asserts++;
          } else {
            directives.push({ t: "assert_malformed", line, bin: pushBin(mod.bytes), text });
            stats.asserts++;
          }
        } catch (e) {
          if (process.env.WASM_SPEC_GEN_DEBUG) console.error(`DEBUG ${file}:${line}:`, e.message);
          // Text wabt cannot parse either: untestable for a binary-only engine.
          directives.push({ t: "assert_malformed_text", line, text, reason: "wat text parsing is outside the binary runtime" });
          stats.malformed_text++;
        }
        continue;
      }

      if (head === "assert_invalid" || head === "assert_unlinkable") {
        const inner = d.list[1];
        const text = d.list[2] && d.list[2].str !== undefined
          ? Buffer.from(decodeWastString(d.list[2].str)).toString("utf8") : "";
        if (!inner.list || atomOf(inner.list[0]) !== "module") throw new Error(`${file}:${line}: unsupported ${head} payload`);
        try {
          const mod = moduleBytes(inner, file);
          directives.push({ t: head, line, bin: pushBin(mod.bytes), text });
          stats.asserts++;
        } catch (e) {
          directives.push({ t: "skipped_module", line, directive: head, text, reason: `generator: ${String(e.message).slice(0, 120)}` });
          stats.gen_skips++;
        }
        continue;
      }

      throw new Error(`${file}:${line}: unsupported directive ${head}`);
    }
    manifest.files.push({ file, directives });
  }

  writeFileSync(join(outDir, "modules.bin"), Buffer.concat(binParts));
  writeFileSync(join(outDir, "manifest.json"), JSON.stringify(manifest, null, 1) + "\n");
  console.log(`wasm-spec-gen: ${files.length} files, ${stats.modules} modules, ${stats.asserts} testable assertions, ${stats.malformed_text} wat-text skips, ${stats.gen_skips} generator skips, ${binOffset} binary bytes`);
}

await main();
