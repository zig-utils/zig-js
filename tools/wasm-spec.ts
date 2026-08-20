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
    if (kind === "module" || kind === "module_definition") {
      const binary = binaryExpression(
          `${directory}/${command.binary_filename || command.filename}`,
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
        `new WebAssembly.Module(${binaryExpression(`${directory}/${command.filename}`)})`,
        "WebAssembly.CompileError",
      );
    }
    if (kind === "assert_unlinkable")
      return expectedException(
        index,
        command,
        `new WebAssembly.Instance(new WebAssembly.Module(${binaryExpression(`${directory}/${command.filename}`)}),__registry)`,
        "WebAssembly.LinkError",
      );
    if (kind === "assert_uninstantiable")
      return expectedException(
        index,
        command,
        `new WebAssembly.Instance(new WebAssembly.Module(${binaryExpression(`${directory}/${command.filename}`)}),__registry)`,
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
const __report={commands:[]},__modules=Object.create(null),__moduleDefinitions=Object.create(null),__registry=Object.create(null),__externrefs=new Map();let __last=null;
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
  const command = {
    type: "assert_return",
    line: 1,
    action: { type: "invoke", field: "f" },
    expected: [{ type: "i32", value: "1" }],
  };
  const generated = generateCommand(0, command, ".");
  if (
    !generated.includes("__same") ||
    featureArea("core-3", "test/core/gc/i31.wast") !== "gc" ||
    !PRELUDE.includes(
      "Object.prototype.hasOwnProperty.call(e,'value')&&e.value==='null'?a===null",
    )
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
    const jsonPath = `${directory}/${stem(wast)}.json`,
      converted = run(converterCommand(template, converter, wast, jsonPath));
    let commands: Item[] = [];
    if (converted.exitCode !== 0)
      commands = [
        {
          index: 0,
          line: 0,
          type: "conversion",
          status: "runner_error",
          mode: "javascript_api",
          detail: converted.stderr.trim(),
        },
      ];
    else {
      const document = JSON.parse(readText(jsonPath));
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
          commands = JSON.parse(evaluated.stdout).commands;
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
