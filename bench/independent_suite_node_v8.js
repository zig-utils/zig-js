#!/usr/bin/env node
// Minimal Node/V8 adapter for the pinned Octane subset (#504). Node is named
// explicitly because this is not a standalone d8 shell or a browser process.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ADAPTER_PATH = fileURLToPath(import.meta.url);

const SUITE_REVISION = "570ad1ccfe86e3eecba0636c8f932ac08edec517";
const SUITE_TREE = "e40d5c8489d05e384f32ed064d1f5286e9c236f3";
const PROTOCOL_MARKER = "__zig_js_independent_suite_v1__";
const BASE = { path: "base.js", sha256: "216612c2e7096a02b3e52b57e9cf9351bbaf180d60938d5c60b85fd756232733" };
const ROWS = {
  richards: { path: "richards.js", sha256: "1246a64a24b931158bf01c24640343259fa74b0226e73bad630bd1f686aa0fa7", licenses: ["BSD-3-Clause"], results: ["Richards"] },
  regexp: { path: "regexp.js", sha256: "a292d6047900c5296ea9e2628453832cc3bfe397e49fddade8aff7b5876c8263", licenses: ["BSD-3-Clause"], results: ["RegExp"] },
  splay: { path: "splay.js", sha256: "f9a6a60d8f205908f5542ad1180abc1902dcdab3dcb4278017c5ce179ee123f7", licenses: ["BSD-3-Clause"], results: ["Splay", "SplayLatency"] },
  navier_stokes: { path: "navier-stokes.js", sha256: "27926de809451c60b0c49a4185c08f97081310d0db166a30c1d202fb656556a2", licenses: ["MIT"], results: ["NavierStokes"] },
  box2d: { path: "box2d.js", sha256: "83b10c280f004e7b156a9e04d09ce4109892ea92788f7c6c963f7fadf29c7bd4", licenses: ["Zlib"], results: ["Box2D"] },
};

function requireValue(condition, message) { if (!condition) throw new Error(message); }
function sha256(bytes) { return crypto.createHash("sha256").update(bytes).digest("hex"); }
function git(args) { return execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim(); }
function sourceRevision(value) { return /^[0-9a-f]{40}$/.test(value || "") ? value : null; }

function verifyEnvironment() {
  for (const [name, value] of [["TZ", "UTC"], ["LC_ALL", "C"], ["LANG", "C"]])
    requireValue(process.env[name] === value, `required environment ${name}=${value}, got ${String(process.env[name])}`);
}

function verifyAdapterIdentity(revision) {
  requireValue(sourceRevision(revision) !== null, "adapter revision must be 40 lowercase hex characters");
  requireValue(git(["rev-parse", "HEAD"]) === revision, "adapter source revision differs from HEAD");
  requireValue(git(["status", "--porcelain=v1", "--untracked-files=all"]) === "", "zig-js worktree is dirty");
}

function readPinned(checkout, identity) {
  const bytes = fs.readFileSync(path.join(checkout, identity.path));
  const actual = sha256(bytes);
  requireValue(actual === identity.sha256, `${identity.path} SHA-256 drift: expected ${identity.sha256}, got ${actual}`);
  return { ...identity, bytes: bytes.toString("utf8") };
}

function positiveScore(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0;
}

function execute(sources, row) {
  const events = [], auxiliary = [];
  let loadIndex = 0, failure = null;
  const beforeCpu = process.cpuUsage(), beforeResources = process.resourceUsage(), started = process.hrtime.bigint();
  let context;
  const sandbox = {
    load(requested) {
      requireValue(typeof requested === "string" && loadIndex < sources.length, "load path/cardinality drift");
      const source = sources[loadIndex++];
      requireValue(requested === source.path, `load order/path mismatch: expected ${source.path}, got ${requested}`);
      return vm.runInContext(source.bytes, context, { filename: source.path });
    },
    print(...args) {
      const copied = args.map(String);
      if (copied[0] === PROTOCOL_MARKER) {
        requireValue(copied.length === 4 && ["result", "error", "score"].includes(copied[1]), "malformed result-capture print");
        events.push({ kind: copied[1], name: copied[2], value: copied[3] });
      } else auxiliary.push({ arguments: copied });
    },
  };
  try {
    context = vm.createContext(sandbox, { name: "zig-js-independent-suite-node-v8" });
    for (const source of sources) vm.runInContext(`load(${JSON.stringify(source.path)});`, context, { filename: "adapter-load.js" });
    vm.runInContext(`BenchmarkSuite.RunSuites({
      NotifyResult(name, result) { print(${JSON.stringify(PROTOCOL_MARKER)}, "result", name, result); },
      NotifyError(name, error) { let detail = String(error); try { if (error && typeof error.stack === "string") detail = error.stack; } catch (_) {} print(${JSON.stringify(PROTOCOL_MARKER)}, "error", name, detail); },
      NotifyScore(score) { print(${JSON.stringify(PROTOCOL_MARKER)}, "score", "selected-geometric-aggregate", score); }
    });`, context, { filename: "adapter-driver.js" });
  } catch (error) {
    failure = error && typeof error.stack === "string" ? error.stack : String(error);
  }
  const elapsed = Number(process.hrtime.bigint() - started), cpu = process.cpuUsage(beforeCpu), afterResources = process.resourceUsage();
  const results = events.filter((event) => event.kind === "result"), scores = events.filter((event) => event.kind === "score"), errors = events.filter((event) => event.kind === "error");
  const valid = failure === null && loadIndex === sources.length && errors.length === 0 && scores.length === 1 && positiveScore(scores[0].value) &&
    JSON.stringify(results.map((event) => event.name)) === JSON.stringify(row.results) && results.every((event) => positiveScore(event.value));
  if (!valid && failure === null) failure = `output contract mismatch: expected ${row.results.length} ordered results and one score, observed ${results.length} results, ${scores.length} scores, and ${errors.length} errors`;
  return {
    valid, failure, events, auxiliary,
    raw: { index: 0, mode: "score", instrumentation_enabled: false, outer_wall_ns: elapsed, cpu_user_ns: cpu.user * 1000, cpu_system_ns: cpu.system * 1000, peak_rss_bytes_before: beforeResources.maxRSS * 1024, peak_rss_bytes_after: afterResources.maxRSS * 1024 },
    validation: { status: valid ? "passed" : "failed", expected_result_names: row.results, observed_result_names: results.map((event) => event.name), final_score_count: scores.length },
  };
}

function selfTest() {
  const sources = [
    { path: "base.js", bytes: "var BenchmarkSuite = { RunSuites(r) { r.NotifyResult('Fixture', '123'); r.NotifyScore('456'); } };" },
    { path: "fixture.js", bytes: "var fixture = 1;" },
  ];
  const result = execute(sources, { results: ["Fixture"] });
  requireValue(result.valid && result.events.length === 2, "Node/V8 adapter fixture failed");
  process.stdout.write("independent-suite Node/V8 adapter self-test: passed\n");
}

function main() {
  if (process.argv.length === 3 && process.argv[2] === "--self-test") return selfTest();
  requireValue(process.argv.length === 6, "usage: independent_suite_node_v8.js <verified-octane-checkout> <row> <adapter-source-revision>");
  const checkout = fs.realpathSync(process.argv[2]), rowId = process.argv[3], revision = process.argv[4];
  // Node keeps one trailing argv slot for parity with native adapter launchers.
  requireValue(process.argv[5] === "score", "Node/V8 adapter supports score mode only");
  const row = ROWS[rowId];
  requireValue(Boolean(row), `unknown or excluded row: ${rowId}`);
  verifyEnvironment();
  verifyAdapterIdentity(revision);
  const sources = [readPinned(checkout, BASE), readPinned(checkout, row)];
  const result = execute(sources, row);
  const executablePath = fs.realpathSync(process.execPath), adapterPath = fs.realpathSync(ADAPTER_PATH);
  const report = {
    schema_version: 1, kind: "node-v8-independent-suite-sample", suite: "octane-2-retired", suite_revision: SUITE_REVISION, suite_tree: SUITE_TREE,
    row: rowId, licenses: row.licenses, mode: "score", publication_status: "diagnostic_single_sample",
    engine: {
      id: "node-v8", executable_path: executablePath, executable_sha256: sha256(fs.readFileSync(executablePath)),
      executable_role: "independently installed Node runtime embedding V8; not d8 and not a browser",
      version_output: `${process.version}; V8 ${process.versions.v8}`, node_version: process.version, v8_version: process.versions.v8,
      adapter_path: adapterPath, adapter_sha256: sha256(fs.readFileSync(adapterPath)), adapter_source_revision: revision,
      argv: process.argv, environment: ["TZ=UTC", "LC_ALL=C", "LANG=C", "network=forbidden"], separate_process: true,
    },
    adapter: { id: "node-v8-vm-octane-minimal-shell-v1", context: "fresh node:vm context", host_globals: ["load", "print"], source_transform: false, loaded_sources: sources.map(({ path, sha256 }) => ({ path, sha256 })) },
    status: result.valid ? "passed" : "failed", failure: result.failure, skip_reason: null,
    upstream_outputs: result.events, auxiliary_outputs: result.auxiliary, raw_samples: [result.raw],
    dispersion: { status: "not_applicable_single_sample", sample_count: 1, statistic: null }, validated_output: result.validation,
    timed_boundary: {
      upstream: "Pinned Octane BenchmarkSuite.RunSingleBenchmark boundary: setup and teardown excluded; warmup unscored; each measurement runs for at least one second or the pinned minimum iteration count.",
      outer: "From immediately before fresh node:vm context creation through completion of the owned RunSuites driver; checkout verification, file reads, SHA-256 validation, JSON serialization, and process teardown are excluded.",
    },
    tier_attribution: { status: "unavailable_public_api", reason: "Node exposes no exact per-context V8 tier, compilation, deoptimization, or generated-code counters through node:vm." },
    gc: { status: "unavailable_public_api", reason: "Node exposes no exact per-context V8 allocation, collection, or pause counters through node:vm." },
  };
  process.stdout.write(`${JSON.stringify(report)}\n`);
  if (!result.valid) process.exitCode = 1;
}

main();
