/** Run the complete benchmark/evidence validator inventory after one TS compile. */
import { selfTest as benchmarkComparison } from "./benchmark-comparison";
import { selfTest as benchmarkPublication } from "./benchmark-publication";
import { selfTest as representativeMatrix } from "./test_representative_matrix";
import { selfTest as representativeBenchmark } from "./representative-benchmark";
import { selfTest as representativeTierAttribution } from "./representative-tier-attribution";
import { selfTest as instrumentationOverhead } from "./instrumentation-overhead";
import { selfTest as buildFeedback } from "./build-feedback";
import { selfTest as performanceAttribution } from "./performance-attribution";
import { selfTest as exactParentRegression } from "./exact-parent-regression";
import { selfTest as algorithmicGrowth } from "./algorithmic-growth";
import { selfTest as gcGenerationBenchmark } from "./gc-generation-benchmark";
import { selfTest as wasmSimdBenchmark } from "./wasm-simd-benchmark";
import { selfTest as wasmThreadsBenchmark } from "./wasm-threads-benchmark";
import { selfTest as objectChurnGcProfile } from "./object-churn-gc-profile";
import { selfTest as independentObjectChurnProfile } from "./independent-object-churn-profile";
import { selfTest as sharedObjectChurnAb } from "./shared-object-churn-ab";
import { selfTest as independentSuiteCollector } from "./independent-suite-collector";
import { selfTest as independentSuiteRecognizer } from "./independent-suite-recognizer";
// Inventory-visible module edges: tools/benchmark-comparison.ts, tools/benchmark-publication.ts,
// tools/test_representative_matrix.ts, tools/representative-benchmark.ts,
// tools/representative-tier-attribution.ts, tools/instrumentation-overhead.ts, tools/build-feedback.ts,
// tools/performance-attribution.ts, tools/exact-parent-regression.ts, tools/algorithmic-growth.ts,
// tools/gc-generation-benchmark.ts, tools/wasm-simd-benchmark.ts, tools/wasm-threads-benchmark.ts,
// tools/object-churn-gc-profile.ts, tools/independent-object-churn-profile.ts,
// tools/shared-object-churn-ab.ts, tools/independent-suite-collector.ts, and tools/independent-suite-recognizer.ts.

type SelfTest = { name: string; run: () => void };

// This is the authoritative Home-driven inventory for `benchmark-comparison-test`.
// Native Zig audits and the ReleaseFast independent-suite adapter remain explicit
// build dependencies because they have different compilers and failure surfaces.
export const benchmarkHarnessSelfTests: SelfTest[] = [
  { name: "benchmark-comparison", run: benchmarkComparison },
  { name: "benchmark-publication", run: benchmarkPublication },
  { name: "representative-matrix", run: representativeMatrix },
  { name: "representative-benchmark", run: representativeBenchmark },
  { name: "representative-tier-attribution", run: representativeTierAttribution },
  { name: "instrumentation-overhead", run: instrumentationOverhead },
  { name: "build-feedback", run: buildFeedback },
  { name: "performance-attribution", run: performanceAttribution },
  { name: "exact-parent-regression", run: exactParentRegression },
  { name: "algorithmic-growth", run: algorithmicGrowth },
  { name: "gc-generation-benchmark", run: gcGenerationBenchmark },
  { name: "wasm-simd-benchmark", run: wasmSimdBenchmark },
  { name: "wasm-threads-benchmark", run: wasmThreadsBenchmark },
  { name: "object-churn-gc-profile", run: objectChurnGcProfile },
  { name: "independent-object-churn-profile", run: independentObjectChurnProfile },
  { name: "shared-object-churn-ab", run: sharedObjectChurnAb },
  { name: "independent-suite-collector", run: independentSuiteCollector },
  { name: "independent-suite-recognizer", run: independentSuiteRecognizer },
];

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

export function selfTest(): void {
  requireValue(benchmarkHarnessSelfTests.length === 18, "benchmark harness self-test inventory width drift");
  const names = benchmarkHarnessSelfTests.map((test) => test.name);
  requireValue(names.every((name, index) => name.length > 0 && names.indexOf(name) === index), "benchmark harness self-test names must be nonempty and unique");

  const failures: string[] = [];
  for (const test of benchmarkHarnessSelfTests) {
    console.log(`START benchmark harness self-test: ${test.name}`);
    try {
      test.run();
      console.log(`PASS benchmark harness self-test: ${test.name}`);
    } catch (error) {
      const failure = `${test.name}: ${String(error)}`;
      failures.push(failure);
      console.error(`FAIL benchmark harness self-test: ${failure}`);
    }
  }
  requireValue(failures.length === 0, `benchmark harness self-test failures:\n${failures.join("\n")}`);
  console.log(`OK benchmark harness self-test inventory: ${benchmarkHarnessSelfTests.length}/${benchmarkHarnessSelfTests.length} passed`);
}

function main(): void {
  const args = process.argv.slice(2);
  requireValue(args.length === 1 && args[0] === "--self-test", "usage: benchmark-harness-self-tests.ts --self-test");
  selfTest();
}

if (process.argv[1] === __filename) main();
