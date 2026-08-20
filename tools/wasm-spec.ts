/** Run and inventory pinned upstream WebAssembly specification corpora. */
import {
  fileExists,
  readHex,
  readText,
  removeTemporaryDirectory,
  run,
  temporaryDirectory,
  writeText,
} from "./lib/home";
declare const __filename: string;
type Item = Record<string, any>;
const DEFAULTS: Record<string, string> = {
  mvp: "docs/.data/wasm-spec-inventory.json",
  "core-2-structural": "docs/.data/wasm-core-2-structural-inventory.json",
  "core-3": "docs/.data/wasm-core-3-inventory.json",
  "core-main-shadow": "docs/.data/wasm-core-main-shadow-inventory.json",
  "simd-movement": "docs/.data/wasm-simd-movement-inventory.json",
  simd: "docs/.data/wasm-simd-inventory.json",
  threads: "docs/.data/wasm-threads-inventory.json",
  "tail-calls": "docs/.data/wasm-tail-call-inventory.json",
  "exception-handling": "docs/.data/wasm-exception-handling-inventory.json",
  "multi-memory": "docs/.data/wasm-multi-memory-runtime-inventory.json",
  memory64: "docs/.data/wasm-memory64-runtime-inventory.json",
  gc: "docs/.data/wasm-gc-runtime-inventory.json",
};
const CONVERTER_ARGS: Record<string, string[]> = {
  threads: ["--enable-threads"],
  "tail-calls": ["--enable-tail-call"],
  "exception-handling": ["--enable-exceptions", "--enable-tail-call"],
  "multi-memory": ["--enable-multi-memory"],
};
function fail(message: string): never {
  throw new Error(`wasm-spec: ${message}`);
}
function dirname(path: string): string {
  const at = path.lastIndexOf("/");
  return at < 0 ? "." : path.slice(0, at);
}
function basename(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
}
function stem(path: string): string {
  const name = basename(path),
    dot = name.lastIndexOf(".");
  return dot < 0 ? name : name.slice(0, dot);
}
function absolute(path: string): string {
  if (path.startsWith("/")) return path;
  const result = run(["pwd", "-P"]);
  if (result.exitCode !== 0) fail(result.stderr);
  return `${result.stdout.trim()}/${path}`;
}
function executable(path: string): string {
  if (path.includes("/")) return absolute(path);
  return checked(["which", path], `find ${path}`);
}
function checked(argv: string[], phase: string, cwd?: string): string {
  const result = run(argv, cwd ? { cwd } : undefined);
  if (result.exitCode !== 0)
    fail(`${phase}: ${result.stderr.trim() || result.stdout.trim()}`);
  return result.stdout.trim();
}
function mkdir(path: string): void {
  checked(["mkdir", "-p", path], `create ${path}`);
}
function metadata(profile: Item): Item {
  return profile.converter;
}
function converterCommand(
  profile: Item,
  converter: string,
  source: string,
  output: string,
): string[] {
  const args = CONVERTER_ARGS[profile.profile] || [];
  return profile.converter.kind === "wasm-tools"
    ? [
        converter,
        "json-from-wast",
        ...args,
        source,
        "-o",
        output,
        "--wasm-dir",
        dirname(output),
      ]
    : [converter, ...args, source, "-o", output];
}
type SExpr = {
  start: number;
  end: number;
  line: number;
  items: Array<SExpr | string>;
  head: string | null;
};
function parseWastForms(source: string): SExpr[] {
  const length = source.length;
  function stringEnd(start: number): number {
    let index = start + 1;
    while (index < length) {
      if (source[index] === "\\") index += 2;
      else if (source[index] === '"') return index + 1;
      else index++;
    }
    fail("unterminated WAST string");
  }
  function skip(start: number): number {
    let index = start;
    while (index < length) {
      if (/\s/.test(source[index])) index++;
      else if (source.startsWith(";;", index)) {
        const newline = source.indexOf("\n", index + 2);
        index = newline < 0 ? length : newline + 1;
      } else if (source.startsWith("(;", index)) {
        let depth = 1;
        index += 2;
        while (index < length && depth > 0) {
          if (source.startsWith("(;", index)) {
            depth++;
            index += 2;
          } else if (source.startsWith(";)", index)) {
            depth--;
            index += 2;
          } else if (source[index] === '"') index = stringEnd(index);
          else index++;
        }
        if (depth !== 0) fail("unterminated WAST block comment");
      } else break;
    }
    return index;
  }
  function expression(start: number): [SExpr, number] {
    if (source[start] !== "(") fail("expected WAST expression");
    const line = source.slice(0, start).split("\n").length;
    let index = start + 1;
    const items: Array<SExpr | string> = [];
    while (true) {
      index = skip(index);
      if (index >= length) fail(`unterminated WAST expression at line ${line}`);
      if (source[index] === ")") {
        const head = typeof items[0] === "string" ? items[0] : null;
        return [{ start, end: index + 1, line, items, head }, index + 1];
      }
      if (source[index] === "(") {
        const [child, next] = expression(index);
        items.push(child);
        index = next;
        continue;
      }
      const atomStart = index;
      if (source[index] === '"') index = stringEnd(index);
      else
        while (
          index < length &&
          !/\s/.test(source[index]) &&
          source[index] !== "(" &&
          source[index] !== ")"
        )
          index++;
      items.push(source.slice(atomStart, index));
    }
  }
  const forms: SExpr[] = [];
  let index = 0;
  while (true) {
    index = skip(index);
    if (index >= length) return forms;
    if (source[index] !== "(")
      fail(`unexpected WAST token at line ${source.slice(0, index).split("\n").length}`);
    const [form, next] = expression(index);
    forms.push(form);
    index = next;
  }
}
function namedModule(form: SExpr): string | null {
  if (form.head !== "module" || typeof form.items[1] !== "string") return null;
  return form.items[1].startsWith("$") ? form.items[1] : null;
}
function threadParts(form: SExpr): {
  name: string;
  shared: string[];
  body: SExpr[];
} {
  if (form.head !== "thread" || typeof form.items[1] !== "string")
    fail(`malformed thread at line ${form.line}`);
  const shared: string[] = [],
    body: SExpr[] = [];
  for (const item of form.items.slice(2)) {
    if (typeof item === "string") fail(`malformed thread item at line ${form.line}`);
    if (item.head !== "shared") {
      body.push(item);
      continue;
    }
    const module = item.items[1];
    if (
      item.items.length !== 2 ||
      typeof module === "string" ||
      module?.head !== "module" ||
      module.items.length !== 2 ||
      typeof module.items[1] !== "string"
    )
      fail(`malformed shared module at line ${item.line}`);
    shared.push(module.items[1]);
  }
  return { name: form.items[1], shared, body };
}
function maskedScopeSource(source: string, forms: SExpr[]): string {
  const mask = (text: string) => text.replace(/[^\n]/g, " ");
  let output = "",
    cursor = 0;
  for (const form of forms) {
    output += mask(source.slice(cursor, form.start));
    const text = source.slice(form.start, form.end);
    output += form.head === "thread" || form.head === "wait" ? mask(text) : text;
    cursor = form.end;
  }
  return output + mask(source.slice(cursor));
}
function rewriteBinaryPaths(document: Item, directory: string): void {
  for (const command of document.commands || [])
    if (command.filename && !String(command.filename).startsWith("/"))
      command.filename = `${directory}/${command.filename}`;
}
function compileThreadScope(
  source: string,
  forms: SExpr[],
  inheritedModules: Map<string, string>,
  profile: Item,
  converter: string,
  directory: string,
  scopeId: { value: number },
): Item {
  const localModules = new Map(inheritedModules);
  for (const form of forms) {
    const name = namedModule(form);
    if (name) localModules.set(name, source.slice(form.start, form.end));
  }
  const injected = Array.from(inheritedModules.entries()),
    prefix = injected.map((entry) => `${entry[1]}\n`).join(""),
    prefixLines = (prefix.match(/\n/g) || []).length,
    scopeDirectory = `${directory}/scope-${scopeId.value++}`,
    wastPath = `${scopeDirectory}/scope.wast`,
    jsonPath = `${scopeDirectory}/scope.json`;
  mkdir(scopeDirectory);
  writeText(wastPath, prefix + maskedScopeSource(source, forms));
  const converted = run(converterCommand(profile, converter, wastPath, jsonPath));
  if (converted.exitCode !== 0)
    fail(converted.stderr.trim() || converted.stdout.trim() || "thread scope conversion failed");
  const document = JSON.parse(readText(jsonPath)),
    convertedCommands: Item[] = document.commands || [];
  if (
    convertedCommands.length < injected.length ||
    convertedCommands.slice(0, injected.length).some((command) => command.type !== "module")
  )
    fail("injected shared module prefix did not convert canonically");
  const commands = convertedCommands.slice(injected.length);
  for (const command of commands)
    command.line = Math.max(0, Number(command.line || 0) - prefixLines);
  document.commands = commands;
  rewriteBinaryPaths(document, scopeDirectory);

  const specials: Item[] = [];
  forms.forEach((form, ordinal) => {
    if (form.head === "thread") {
      const parts = threadParts(form),
        missing = parts.shared.filter((name) => !localModules.has(name));
      if (missing.length)
        fail(`unknown shared module(s) at line ${form.line}: ${missing.join(", ")}`);
      const nestedModules = new Map<string, string>();
      for (const name of parts.shared) nestedModules.set(name, localModules.get(name)!);
      specials.push({
        type: "thread",
        line: form.line,
        name: parts.name,
        shared: parts.shared,
        document: compileThreadScope(
          source,
          parts.body,
          nestedModules,
          profile,
          converter,
          directory,
          scopeId,
        ),
        _ordinal: ordinal,
      });
    } else if (form.head === "wait") {
      if (form.items.length !== 2 || typeof form.items[1] !== "string")
        fail(`malformed wait at line ${form.line}`);
      specials.push({ type: "wait", line: form.line, name: form.items[1], _ordinal: ordinal });
    }
  });
  const merged = [...commands, ...specials];
  merged.forEach((command, ordinal) => {
    if (command._ordinal == null) command._ordinal = forms.length + ordinal;
  });
  merged.sort(
    (left, right) =>
      Number(left.line || 0) - Number(right.line || 0) ||
      Number(left._ordinal) - Number(right._ordinal),
  );
  for (const command of merged) delete command._ordinal;
  document.commands = merged;
  return document;
}
function compileThreadScript(
  source: string,
  profile: Item,
  converter: string,
  directory: string,
): Item {
  return compileThreadScope(
    source,
    parseWastForms(source),
    new Map(),
    profile,
    converter,
    directory,
    { value: 0 },
  );
}
function valueExpression(value: Item): string {
  const raw = JSON.stringify(String(value.value));
  if (value.type === "i32") return `(Number(${raw})|0)`;
  if (value.type === "i64") return `BigInt.asIntN(64,BigInt(${raw}))`;
  if (value.type === "f32")
    return String(value.value).startsWith("nan:") ? "NaN" : `__f32(${raw})`;
  if (value.type === "f64")
    return String(value.value).startsWith("nan:") ? "NaN" : `__f64(${raw})`;
  if (["externref", "anyref"].includes(value.type))
    return `__externref(${raw})`;
  if (value.type === "funcref" && value.value === "null") return "null";
  fail(`unknown value type ${value.type}`);
}
function instanceExpression(action: Item): string {
  return action.module == null
    ? "__last"
    : `__modules[${JSON.stringify(action.module)}]`;
}
function actionExpression(action: Item): string {
  const instance = instanceExpression(action),
    field = JSON.stringify(action.field);
  if (action.type === "get") return `__get(${instance},${field})`;
  if (action.type === "invoke")
    return `${instance}.exports[${field}](${(action.args || []).map(valueExpression).join(",")})`;
  fail(`unknown action type ${action.type}`);
}
function rawBits(value: Item): string {
  const widths: Item = { i32: 32, f32: 32, i64: 64, f64: 64 };
  if (widths[value.type])
    return BigInt.asUintN(widths[value.type], BigInt(value.value)).toString();
  if (value.type !== "v128") fail(`unknown raw value type ${value.type}`);
  const laneWidths: Item = {
      i8: 8,
      i16: 16,
      i32: 32,
      i64: 64,
      f32: 32,
      f64: 64,
    },
    width = laneWidths[value.lane_type];
  if (
    !width ||
    !Array.isArray(value.value) ||
    value.value.length * width !== 128
  )
    fail(`invalid v128 ${value.lane_type} lanes`);
  let bits = 0n,
    mask = (1n << BigInt(width)) - 1n;
  value.value.forEach((lane: string, index: number) => {
    bits |= (BigInt(lane) & mask) << (BigInt(index) * BigInt(width));
  });
  return bits.toString();
}
function rawAction(action: Item): string {
  const target = `${instanceExpression(action)}.exports[${JSON.stringify(action.field)}]`,
    args = (action.args || [])
      .map((value: Item) => `,${JSON.stringify(rawBits(value))}`)
      .join("");
  return `__wasmSpecInvokeBits(${target}${action.type === "invoke" ? args : ""})`;
}
function vectorValues(command: Item): Item[] {
  const expected = command.expected || [],
    values = [...(command.action?.args || []), ...expected];
  for (const item of expected)
    if (item.type === "either") values.push(...(item.values || []).flat());
  return values;
}
function vectorAlternatives(command: Item): Item[][] {
  const expected = command.expected || [];
  if (expected.length === 1 && expected[0].type === "either")
    return (expected[0].values || []).map((item: any) =>
      Array.isArray(item) ? item : [item],
    );
  if (command.either)
    return command.either.map((item: any) =>
      Array.isArray(item) ? item : [item],
    );
  return [expected];
}
function vectorComparison(expected: Item[]): string {
  if (!expected.length) return "a===undefined";
  if (
    expected.length === 1 &&
    expected[0].type === "v128" &&
    expected[0].value.some((lane: any) => String(lane).startsWith("nan:"))
  )
    return `__sameV128Bits(a,${JSON.stringify(expected[0].lane_type)},${JSON.stringify(expected[0].value)})`;
  const bits = expected.map(rawBits);
  return expected.length === 1
    ? `a===${JSON.stringify(bits[0])}`
    : `JSON.stringify(a)===${JSON.stringify(JSON.stringify(bits))}`;
}
function binaryExpression(path: string): string {
  const hex = readHex(path),
    bytes: string[] = [];
  for (let index = 0; index < hex.length; index += 2)
    bytes.push(String(parseInt(hex.slice(index, index + 2), 16)));
  return `new Uint8Array([${bytes.join(",")}])`;
}
function binaryPath(directory: string, filename: string): string {
  return filename.startsWith("/") ? filename : `${directory}/${filename}`;
}
function record(
  index: number,
  command: Item,
  status: string,
  detail = "",
  mode = "javascript_api",
): string {
  return `__record(${index},${Number(command.line || 0)},${JSON.stringify(command.type)},${JSON.stringify(status)},${JSON.stringify(detail)},${JSON.stringify(mode)});`;
}
function expectedException(
  index: number,
  command: Item,
  expression: string,
  name: string,
): string {
  return `{let t=false;try{${expression};}catch(e){t=true;if(e instanceof ${name}){${record(index, command, "pass")}}else{__record(${index},${Number(command.line || 0)},${JSON.stringify(command.type)},'fail','expected ${name}, got '+__message(e));}}if(!t){${record(index, command, "fail", `expected ${name}`)}}}`;
}
function generateCommand(
  index: number,
  command: Item,
  directory: string,
): string {
  const kind = command.type;
  try {
    if (kind === "thread") {
      const shared: string[] = command.shared || [],
        sharedValues = shared
          .map((name) => `__modules[${JSON.stringify(name)}]`)
          .join(","),
        sharedInit = shared
          .map(
            (name, position) =>
              `__modules[${JSON.stringify(name)}]=__shared[${position}];`,
          )
          .join(""),
        body = (command.document.commands || [])
          .map((nested: Item, nestedIndex: number) =>
            generateCommand(nestedIndex, nested, directory),
          )
          .join("\n"),
        passed = record(index, command, "pass", "", "proposal_thread");
      return `{try{__threads[${JSON.stringify(command.name)}]=new Thread((__shared)=>{const __report={commands:[]},__modules=Object.create(null),__moduleDefinitions=Object.create(null),__registry=Object.create(null),__threads=Object.create(null);let __last=null;__registry.spectest=__spectest;function __record(index,line,type,status,detail,mode){const e={index,line,type,status,mode:mode||'javascript_api'};if(detail)e.detail=detail;__report.commands.push(e)}${sharedInit}${body}return __report.commands;},[${sharedValues}]);${passed}}catch(e){__record(${index},${Number(command.line || 0)},'thread','fail',__message(e),'proposal_thread');}}`;
    }
    if (kind === "wait") {
      const passed = record(index, command, "pass", "", "proposal_wait");
      return `{try{const c=__threads[${JSON.stringify(command.name)}];if(!c)throw new Error('unknown thread');const r=c.join();if(!Array.isArray(r))throw new Error('invalid thread report');for(const e of r)__report.commands.push(e);${passed}}catch(e){__record(${index},${Number(command.line || 0)},'wait','fail',__message(e),'proposal_wait');}}`;
    }
    if (kind === "module" || kind === "module_definition") {
      const binary = binaryExpression(
          binaryPath(directory, command.binary_filename || command.filename),
        ),
        name = command.name;
      if (kind === "module_definition")
        return `{try{const d=new WebAssembly.Module(${binary});${name == null ? "" : `__moduleDefinitions[${JSON.stringify(name)}]=d;`}${record(index, command, "pass")}}catch(e){__record(${index},${Number(command.line || 0)},'module_definition','fail',__message(e));}}`;
      return `{try{__last=new WebAssembly.Instance(new WebAssembly.Module(${binary}),__registry);${name == null ? "" : `__modules[${JSON.stringify(name)}]=__last;`}${record(index, command, "pass")}}catch(e){__record(${index},${Number(command.line || 0)},'module','fail',__message(e));}}`;
    }
    if (kind === "module_instance")
      return `{try{__last=new WebAssembly.Instance(__moduleDefinitions[${JSON.stringify(command.module)}],__registry);__modules[${JSON.stringify(command.instance)}]=__last;${record(index, command, "pass")}}catch(e){__record(${index},${Number(command.line || 0)},'module_instance','fail',__message(e));}}`;
    if (kind === "register")
      return `{try{__registry[${JSON.stringify(command.as)}]=${command.name == null ? "__last" : `__modules[${JSON.stringify(command.name)}]`}.exports;${record(index, command, "pass")}}catch(e){__record(${index},${Number(command.line || 0)},'register','fail',__message(e));}}`;
    if (kind === "action")
      return `{try{${actionExpression(command.action)};${record(index, command, "pass")}}catch(e){__record(${index},${Number(command.line || 0)},'action','fail',__message(e));}}`;
    if (kind === "assert_return") {
      if (vectorValues(command).some((value) => value.type === "v128")) {
        const alternatives = vectorAlternatives(command),
          nanPolicy = alternatives.some((items) =>
            items.some(
              (value) =>
                value.type === "v128" &&
                value.value.some((lane: any) =>
                  String(lane).startsWith("nan:"),
                ),
            ),
          ),
          mode = nanPolicy ? "vector_nan_policy" : "vector_bits",
          comparison =
            alternatives
              .map(vectorComparison)
              .map((item) => `(${item})`)
              .join("||") || "false";
        return `{try{const a=${rawAction(command.action)};if(${comparison}){${record(index, command, "pass", "", mode)}}else{${record(index, command, "fail", "raw vector result mismatch", mode)}}}catch(e){__record(${index},${Number(command.line || 0)},'assert_return','fail',__message(e),${JSON.stringify(mode)});}}`;
      }
      const scalarValues = [
          ...(command.expected || []),
          ...(command.action?.args || []),
        ],
        bitExact =
          !(command.expected || []).some((value: Item) =>
            String(value.value).startsWith("nan:"),
          ) &&
          scalarValues.some((value: Item) => {
            if (!["f32", "f64"].includes(value.type)) return false;
            const bits = BigInt(value.value),
              exponent =
                value.type === "f32" ? 0x7f800000n : 0x7ff0000000000000n,
              fraction =
                value.type === "f32" ? 0x007fffffn : 0x000fffffffffffffn;
            return (bits & exponent) === exponent && (bits & fraction) !== 0n;
          });
      if (bitExact && (command.expected || []).length === 1)
        return `{try{const a=${rawAction(command.action)};if(a===${JSON.stringify(rawBits(command.expected[0]))}){${record(index, command, "pass", "", "bit_exact")}}else{${record(index, command, "fail", "raw result mismatch", "bit_exact")}}}catch(e){__record(${index},${Number(command.line || 0)},'assert_return','fail',__message(e),'bit_exact');}}`;
      const choices = command.either || [command.expected || []],
        comparisons =
          choices
            .map(
              (choice: any) =>
                `__same(a,${JSON.stringify(Array.isArray(choice) ? choice : [choice])})`,
            )
            .join("||") || "false";
      return `{try{const a=${actionExpression(command.action)};if(${comparisons}){${record(index, command, "pass")}}else{${record(index, command, "fail", "result mismatch")}}}catch(e){__record(${index},${Number(command.line || 0)},'assert_return','fail',__message(e));}}`;
    }
    if (
      ["assert_return_canonical_nan", "assert_return_arithmetic_nan"].includes(
        kind,
      )
    )
      return `{try{const a=${actionExpression(command.action)};if(Number.isNaN(a)){${record(index, command, "pass")}}else{${record(index, command, "fail", "expected NaN")}}}catch(e){__record(${index},${Number(command.line || 0)},${JSON.stringify(kind)},'fail',__message(e));}}`;
    if (["assert_trap", "assert_exhaustion"].includes(kind))
      return expectedException(
        index,
        command,
        actionExpression(command.action),
        "WebAssembly.RuntimeError",
      );
    if (kind === "assert_exception")
      return expectedException(
        index,
        command,
        actionExpression(command.action),
        "WebAssembly.Exception",
      );
    if (["assert_malformed", "assert_invalid"].includes(kind)) {
      if (command.module_type === "text")
        return record(
          index,
          command,
          "not_applicable",
          "text-format syntax is not exposed by the JavaScript binary API",
          "not_applicable",
        );
      return expectedException(
        index,
        command,
        `new WebAssembly.Module(${binaryExpression(binaryPath(directory, command.filename))})`,
        "WebAssembly.CompileError",
      );
    }
    if (kind === "assert_unlinkable")
      return expectedException(
        index,
        command,
        `new WebAssembly.Instance(new WebAssembly.Module(${binaryExpression(binaryPath(directory, command.filename))}),__registry)`,
        "WebAssembly.LinkError",
      );
    if (kind === "assert_uninstantiable")
      return expectedException(
        index,
        command,
        `new WebAssembly.Instance(new WebAssembly.Module(${binaryExpression(binaryPath(directory, command.filename))}),__registry)`,
        "WebAssembly.RuntimeError",
      );
  } catch (error) {
    return record(index, command, "runner_error", String(error));
  }
  return record(index, command, "runner_error", "unsupported command kind");
}
// wasm-tools encodes `(ref.null exn)` as an `exnref` with an explicit `"null"`
// value; `nullexnref`/`refnull` are separate bottom-type spellings. Match that
// value before requiring the host object used for a non-null exception.
const PRELUDE = `
const __report={commands:[]},__modules=Object.create(null),__moduleDefinitions=Object.create(null),__registry=Object.create(null),__threads=Object.create(null),__externrefs=new Map();let __last=null;
const __scratch=new ArrayBuffer(8),__view=new DataView(__scratch);
function __f32(x){__view.setUint32(0,Number(x),true);return __view.getFloat32(0,true)}
function __f64(x){__view.setBigUint64(0,BigInt(x),true);return __view.getFloat64(0,true)}
function __f32bits(x){__view.setFloat32(0,x,true);return __view.getUint32(0,true)}
function __f64bits(x){__view.setFloat64(0,x,true);return __view.getBigUint64(0,true)}
function __externref(x){if(x==='null')return null;if(!__externrefs.has(x))__externrefs.set(x,{specExternref:x});return __externrefs.get(x)}
function __record(index,line,type,status,detail,mode){const e={index,line,type,status,mode:mode||'javascript_api'};if(detail)e.detail=detail;__report.commands.push(e)}
function __message(e){try{return String(e)}catch(_){return '<unprintable>'}}
function __get(i,f){const v=i.exports[f];return v instanceof WebAssembly.Global?v.value:v}
function __sameOne(a,e){if(e.type==='i32')return(a|0)===(Number(e.value)|0);if(e.type==='i64')return a===BigInt.asIntN(64,BigInt(e.value));if(e.type==='f32')return String(e.value).startsWith('nan:')?Number.isNaN(a):__f32bits(a)===Number(e.value);if(e.type==='f64')return String(e.value).startsWith('nan:')?Number.isNaN(a):__f64bits(a)===BigInt(e.value);if(e.type==='externref'||e.type==='anyref')return Object.prototype.hasOwnProperty.call(e,'value')?a===__externref(e.value):a!=null;if(e.type==='i31ref')return typeof a==='number';if(e.type==='eqref'||e.type==='structref'||e.type==='arrayref'||e.type==='exnref')return Object.prototype.hasOwnProperty.call(e,'value')&&e.value==='null'?a===null:a!==null&&typeof a==='object';if(e.type==='funcref')return e.value==='null'?a===null:typeof a==='function';if(e.type==='refnull'||String(e.type).startsWith('null'))return a===null;return false}
function __same(a,e){if(e.length===0)return a===undefined;const v=e.length===1?[a]:a;if(!Array.isArray(v)||v.length!==e.length)return false;return e.every((x,i)=>__sameOne(v[i],x))}
function __sameV128Bits(actual,laneType,expected){const widths={i8:8n,i16:16n,i32:32n,i64:64n,f32:32n,f64:64n},width=widths[laneType];if(!width)return false;let bits;try{bits=BigInt(actual)}catch(_){return false}const mask=(1n<<width)-1n;for(let i=0;i<expected.length;i++){const lane=(bits>>(BigInt(i)*width))&mask,value=expected[i];if(value==='nan:canonical'){const magnitude=lane&(laneType==='f32'?0x7fffffffn:0x7fffffffffffffffn),canonical=laneType==='f32'?0x7fc00000n:0x7ff8000000000000n;if(magnitude!==canonical)return false}else if(value==='nan:arithmetic'){const quiet=laneType==='f32'?0x7fc00000n:0x7ff8000000000000n;if((lane&quiet)!==quiet)return false}else if(lane!==(BigInt(value)&mask))return false}return true}
const __spectest={print(){},print_i32(){},print_i64(){},print_f32(){},print_f64(){},print_i32_f32(){},print_f64_f64(){},global_i32:666,global_i64:666n,global_f32:666.6,global_f64:666.6,table:new WebAssembly.Table({initial:10,maximum:20,element:'anyfunc'}),memory:new WebAssembly.Memory({initial:1,maximum:2})};__registry.spectest=__spectest;
`;
function counts(commands: Item[]): Item {
  const out: Item = { pass: 0, fail: 0, not_applicable: 0, runner_error: 0 };
  for (const command of commands)
    out[command.status] = (out[command.status] || 0) + 1;
  out.total = commands.length;
  return out;
}
function normalizeCommandIndexes(commands: Item[]): Item[] {
  return commands.map((command, index) => ({ ...command, index }));
}
function runnerErrorDetails(
  commands: Item[],
  limit = 3,
  maxLength = 2000,
): string[] {
  const details: string[] = [],
    seen = new Set<string>();
  for (const command of commands) {
    if (command.status !== "runner_error") continue;
    let detail = String(command.detail || "runner failed without detail").trim();
    if (seen.has(detail)) continue;
    seen.add(detail);
    if (detail.length > maxLength) detail = `${detail.slice(0, maxLength - 1)}…`;
    details.push(detail);
    if (details.length === limit) break;
  }
  return details;
}
function featureArea(profile: string, path: string): string {
  if (profile === "mvp") return "mvp";
  const direct: Item = {
    "simd-movement": "fixed_width_simd_movement",
    simd: "fixed_width_simd",
    threads: "threads",
    "tail-calls": "tail_calls",
    "exception-handling": "exception_handling",
    "multi-memory": "multi_memory",
    memory64: "memory64",
    gc: "gc",
  };
  if (direct[profile]) return direct[profile];
  for (const [part, area] of [
    ["bulk-memory", "bulk_memory"],
    ["exceptions", "exception_handling"],
    ["gc", "gc"],
    ["memory64", "memory64"],
    ["multi-memory", "multi_memory"],
    ["relaxed-simd", "relaxed_simd"],
    ["simd", "fixed_width_simd"],
  ])
    if (path.split("/").includes(part)) return area;
  const name = stem(path);
  if (
    ["call_ref", "return_call_ref", "br_on_null", "br_on_non_null"].includes(
      name,
    )
  )
    return "typed_function_references";
  if (["return_call", "return_call_indirect"].includes(name))
    return "tail_calls";
  return "shared_core";
}
function parseArgs(): Item {
  const out: Item = {
    profile: "mvp",
    converter: process.env.WAST2JSON || "wast2json",
    engine: "zig-out/bin/wasm-spec-eval",
    commandShards: 1,
    allowFailures: false,
    changedOnly: false,
  };
  for (let i = 2; i < process.argv.length; i++) {
    const arg = process.argv[i];
    if (arg === "--allow-failures") out.allowFailures = true;
    else if (arg === "--changed-only") out.changedOnly = true;
    else if (arg === "--self-test") out.selfTest = true;
    else {
      const value = process.argv[++i];
      if (value == null) fail(`${arg} requires a value`);
      const key: Item = {
        "--profile": "profile",
        "--spec-root": "specRoot",
        "--converter": "converter",
        "--wast2json": "converter",
        "--engine": "engine",
        "--inventory": "inventory",
        "--filter": "filter",
        "--timeout": "timeout",
        "--keep-work": "keepWork",
        "--command-shards": "commandShards",
      };
      if (!key[arg]) fail(`unknown argument ${arg}`);
      out[key[arg]] = value;
    }
  }
  return out;
}
function selfTest(): void {
  let rejected = 0;
  try {
    parseWastForms("(; never closed");
  } catch {
    rejected++;
  }
  try {
    threadParts(parseWastForms("(thread $T (shared (module)))")[0]);
  } catch {
    rejected++;
  }
  const command = {
    type: "assert_return",
    line: 1,
    action: { type: "invoke", field: "f" },
    expected: [{ type: "i32", value: "1" }],
  };
  const generated = generateCommand(0, command, "."),
    threadSource =
      ';; lead\n(module $M (func (export "(; text ;)")))\n' +
      "(; outer (; nested ;) ;)\n" +
      "(thread $T (shared (module $M)) (wait $Inner))\n(wait $T)\n",
    forms = parseWastForms(threadSource),
    parts = threadParts(forms[1]),
    masked = maskedScopeSource(threadSource, forms),
    thread = generateCommand(
      1,
      {
        type: "thread",
        line: 4,
        name: "$T",
        shared: ["$M"],
        document: { commands: [] },
      },
      ".",
    ),
    wait = generateCommand(
      2,
      { type: "wait", line: 5, name: "$T" },
      ".",
    ),
    details = runnerErrorDetails([
      { status: "runner_error", detail: "engine exited 1" },
      { status: "runner_error", detail: "engine exited 1" },
    ]);
  if (
    !generated.includes("__same") ||
    featureArea("core-3", "test/core/gc/i31.wast") !== "gc" ||
    !PRELUDE.includes(
      "Object.prototype.hasOwnProperty.call(e,'value')&&e.value==='null'?a===null",
    ) ||
    forms.map((form) => form.head).join(",") !== "module,thread,wait" ||
    forms.map((form) => form.line).join(",") !== "2,4,5" ||
    parts.name !== "$T" ||
    parts.shared.join(",") !== "$M" ||
    parts.body[0]?.head !== "wait" ||
    masked.includes("thread") ||
    !masked.includes("(module $M") ||
    !thread.includes("proposal_thread") ||
    !thread.includes('__modules["$M"]=__shared[0]') ||
    !wait.includes("proposal_wait") ||
    !wait.includes(".join()") ||
    details.length !== 1 ||
    details[0] !== "engine exited 1" ||
    rejected !== 2
  )
    fail("self-test failed");
  console.log("WebAssembly corpus driver self-test: PASS");
}
function main(): void {
  const args = parseArgs();
  if (args.selfTest) {
    selfTest();
    return;
  }
  if (!DEFAULTS[args.profile]) fail(`unknown profile ${args.profile}`);
  const template = JSON.parse(readText(DEFAULTS[args.profile]));
  template.profile ||= args.profile;
  template.features ||= [];
  const specRoot = absolute(
      args.specRoot ||
        (args.profile === "core-3" ? "wasm-spec-wg3" : "wasm-spec-wg1"),
    ),
    converter = executable(args.converter),
    engine = absolute(args.engine),
    inventoryPath = args.inventory || DEFAULTS[args.profile];
  if (!fileExists(engine))
    fail(`missing evaluator at ${engine}; run zig build wasm-spec-eval`);
  const actual = checked(
    ["git", "rev-parse", "HEAD"],
    "read corpus revision",
    specRoot,
  );
  if (actual !== template.spec.commit)
    fail(
      `wasm-spec pin drift: expected ${template.spec.commit}, found ${actual}`,
    );
  if (template.converter.version !== "1.0.12") {
    const version = checked([converter, "--version"], "read converter version");
    if (!version.includes(template.converter.version))
      fail(
        `converter version drift: expected ${template.converter.version}, found ${version}`,
      );
  }
  const found = checked(
    ["find", specRoot, "-type", "f", "-name", "*.wast"],
    "enumerate corpus",
  )
    .split("\n")
    .filter(Boolean)
    .sort()
    .filter((path) => {
      const relative = path.slice(specRoot.length + 1),
        prefix = template.spec.suite.split("*")[0];
      if (!relative.startsWith(prefix)) return false;
      return (
        template.spec.suite.includes("**") ||
        dirname(relative) === prefix.slice(0, -1)
      );
    });
  const declared =
    template.spec.declared_files &&
    template.spec.files_declared < template.spec.files_available
      ? new Set(template.spec.declared_files)
      : null;
  let selected = found
    .filter((path) => !declared || declared.has(basename(path)))
    .filter((path) => !args.filter || path.includes(args.filter));
  if (args.changedOnly) {
    const changed = new Set(
      checked(
        [
          "git",
          "diff",
          "--name-only",
          template.observation.baseline_commit,
          template.observation.commit,
          "--",
          "test/core",
        ],
        "select changed shadow files",
        specRoot,
      ).split("\n"),
    );
    selected = selected.filter((path) =>
      changed.has(path.slice(specRoot.length + 1)),
    );
  }
  if (!selected.length) fail("no corpus files selected");
  const temporary = !args.keepWork,
    work = absolute(args.keepWork || temporaryDirectory("zig-js-wasm-spec"));
  mkdir(work);
  const files: Item[] = [];
  for (let n = 0; n < selected.length; n++) {
    const wast = selected[n],
      relative = wast.slice(specRoot.length + 1),
      directory = `${work}/${relative.slice(0, -5)}`;
    mkdir(directory);
    const jsonPath = `${directory}/${stem(wast)}.json`;
    let commands: Item[] = [];
    let document: Item | null = null,
      conversionDetail = "";
    const source = readText(wast),
      proposalScript =
        args.profile === "threads" &&
        (source.includes("(thread") || source.includes("(wait"));
    if (proposalScript) {
      try {
        document = compileThreadScript(source, template, converter, directory);
      } catch (error) {
        conversionDetail = String(error);
      }
    } else {
      const converted = run(
        converterCommand(template, converter, wast, jsonPath),
      );
      if (converted.exitCode !== 0)
        conversionDetail = converted.stderr.trim() || converted.stdout.trim();
      else document = JSON.parse(readText(jsonPath));
    }
    if (conversionDetail)
      commands = [
        {
          index: 0,
          line: 0,
          type: "conversion",
          status: "runner_error",
          mode: "javascript_api",
          detail: conversionDetail,
        },
      ];
    else if (document) {
      const script = `${PRELUDE}\n${document.commands.map((command: Item, index: number) => generateCommand(index, command, directory)).join("\n")}\nJSON.stringify(__report);`;
      const scriptPath = `${directory}/${stem(wast)}.js`;
      writeText(scriptPath, script);
      const evaluated = run([engine, scriptPath], {
        timeoutMs:
          Number(
            args.timeout ||
              (["core-2-structural", "core-3", "core-main-shadow"].includes(
                args.profile,
              )
                ? 600
                : 120),
          ) * 1000,
        env:
          args.profile === "mvp"
            ? undefined
            : {
                WASM_SPEC_PROFILE:
                  args.profile === "simd-movement"
                    ? "simd"
                    : ["core-3", "core-main-shadow"].includes(args.profile)
                      ? "core-3"
                      : args.profile,
              },
      });
      if (evaluated.timedOut)
        commands = document.commands.map((c: Item, index: number) => ({
          index,
          line: c.line || 0,
          type: c.type,
          status: "runner_error",
          mode: "javascript_api",
          detail: "engine timeout",
        }));
      else if (evaluated.exitCode !== 0)
        commands = document.commands.map((c: Item, index: number) => ({
          index,
          line: c.line || 0,
          type: c.type,
          status: "runner_error",
          mode: "javascript_api",
          detail:
            evaluated.stderr.trim() || `engine exited ${evaluated.exitCode}`,
        }));
      else
        try {
          commands = normalizeCommandIndexes(
            JSON.parse(evaluated.stdout).commands,
          );
        } catch (e) {
          commands = document.commands.map((c: Item, index: number) => ({
            index,
            line: c.line || 0,
            type: c.type,
            status: "runner_error",
            mode: "javascript_api",
            detail: `invalid evaluator JSON: ${e}`,
          }));
        }
    }
    const area = featureArea(args.profile, relative);
    for (const command of commands) command.feature_area = area;
    const entry = {
      path: relative,
      feature_area: area,
      commands,
      counts: counts(commands),
    };
    files.push(entry);
    console.log(
      `[${n + 1}/${selected.length}] ${basename(wast)}: ${entry.counts.pass} pass, ${entry.counts.fail} fail, ${entry.counts.not_applicable} n/a, ${entry.counts.runner_error} runner`,
    );
    for (const detail of runnerErrorDetails(commands))
      console.error(`  runner error: ${detail}`);
  }
  const all = files.flatMap((entry) => entry.commands),
    totals = counts(all),
    areas: Item = {};
  for (const area of Array.from(
    new Set(files.map((entry) => entry.feature_area)),
  ).sort())
    areas[area] = counts(
      all.filter((command) => command.feature_area === area),
    );
  const inventory: Item = {
    schema_version: 2,
    kind: template.kind,
    profile: args.profile,
    features: template.features,
    spec: {
      ...template.spec,
      files_available: found.length,
      files_declared: declared ? declared.size : found.length,
      files_scored: selected.length,
      declared_files: declared ? Array.from(declared) : found.map(basename),
    },
    converter: metadata(template),
    engine_commit: checked(
      ["git", "rev-parse", "HEAD"],
      "read engine revision",
    ),
    command_shards: Number(args.commandShards),
    totals,
    totals_by_feature_area: areas,
    files,
  };
  if (template.accepted_score === false) {
    inventory.accepted_score = false;
    inventory.observation = {
      ...template.observation,
      selection: args.changedOnly ? "changed_files" : "complete_snapshot",
    };
  }
  mkdir(dirname(inventoryPath));
  writeText(inventoryPath, JSON.stringify(inventory, null, 2) + "\n");
  console.log(
    `TOTAL: ${totals.pass}/${totals.total} pass, ${totals.fail} fail, ${totals.not_applicable} n/a, ${totals.runner_error} runner; inventory=${inventoryPath}`,
  );
  if (temporary) removeTemporaryDirectory(work);
  if (!args.allowFailures && (totals.fail || totals.runner_error))
    fail("corpus contains failures");
}
if (process.argv[1] === __filename) main();
