---
layout: home
title: zig-js — a JavaScript engine in pure Zig
hero:
  name: zig-js
  text: A JavaScript engine in pure Zig
  tagline: A tree-walking interpreter, a bytecode VM, and native tiers with zero C dependencies — plus a precise GC, GIL-free threads, WebAssembly, and a JavaScriptCore-shaped C API subset. Measured against the real test262 corpus.
  actions:
    - theme: brand
      text: Get Started →
      link: /guide/
    - theme: alt
      text: Architecture
      link: /architecture
---

## Conformance

<Test262Progress :stats="data.test262" />

## Run it yourself

<Terminal title="zig build test262 -Doptimize=ReleaseFast">
<span class="cm"># Build the engine and run the pinned tc39/test262 corpus</span>
<span class="pr">❯</span> zig build test262 -Doptimize=ReleaseFast
<span class="cm">----------------------------------------------</span>
<span class="cy">VALID</span> (can we run it):  <span class="ok">{{ data.test262.valid.passing }}/{{ data.test262.valid.total }}</span> (<span class="hl">{{ data.test262.valid.percentage }}%</span>)   parse-fail {{ data.test262.valid.parseFail }} · runtime-fail {{ data.test262.valid.runtimeFail }} · host-fail {{ data.test262.valid.hostFail }}
<span class="cy">NEGATIVE</span> (strictness):  {{ data.test262.negative.passing }}/{{ data.test262.negative.total }} (<span class="hl">{{ data.test262.negative.percentage }}%</span>)
</Terminal>

## What it is

<div class="cards">
<FeatureCard tag="// pure-zig" title="No C dependencies">Lexer, parser, interpreter, bytecode VM, and every builtin are written from scratch in Zig. One static library, no system JavaScriptCore.</FeatureCard>
<FeatureCard tag="// tiered" title="Tree-walk → VM → native">A correct tree-walking evaluator, a suspendable stack VM with slot-allocated locals and frame-linked closures, object shapes and inline caches, and AArch64 baseline and optimizing tiers that always keep an exact interpreter fallback.</FeatureCard>
<FeatureCard tag="// parallel" title="GC and real threads">A precise tracing collector with generational collection and explicit compaction, plus GIL-free shared-realm Threads running JavaScript on real OS threads — gated by whole-corpus ThreadSanitizer sweeps.</FeatureCard>
<FeatureCard tag="// c-api" title="C API subset">Exports the implemented public C API surface — <code>JSGlobalContextCreate</code>, <code>JSEvaluateScript</code>, and friends — for hosts that only need that subset, without treating compatibility shims as permanent before stabilization.</FeatureCard>
<FeatureCard tag="// conformance" title="Measured, scoped">Scored against the real test262 suite with a crash-proof subprocess harness. Current runs report zero skips, zero exclusions, and no configured VALID failures.</FeatureCard>
</div>

## Per-suite breakdown

<table class="suites"><thead><tr><th>Suite</th><th>Passing</th><th>Total</th><th>Rate</th></tr></thead><tbody>
@foreach (data.test262.suites as s)
<tr><td>test/{{ s.name }}</td><td>{{ s.passing }}</td><td>{{ s.total }}</td><td>{{ s.percentage }}%<span class="mini"><i style="width: {{ s.percentage }}%"></i></span></td></tr>
@endforeach
</tbody></table>

> Numbers come from `docs/.data/test262.json`. Regenerate them after a run with `bun run docs:data` — the homepage and conformance page update automatically.

## Where engines like this go

zig-js is built as a general embeddable JavaScript engine for Zig applications, language runtimes, tools, and hosts that want to own their JS stack.

Start with [features](/features/) for what the engine implements, [advanced](/advanced/) for embedding it and understanding its internals, or the [architecture](/architecture) deep-dive, [conformance](/conformance) methodology, and [C-API](/api) embedding guide.
