---
layout: home
title: zig-js — a JavaScript engine in pure Zig
hero:
  name: zig-js
  text: A JavaScript engine in pure Zig
  tagline: A tree-walking interpreter and a tiered bytecode VM with zero C dependencies — plus a JavaScriptCore-shaped C API subset. Measured against the real test262 corpus.
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
<FeatureCard tag="// tiered" title="Tree-walk → VM → shapes">A correct tree-walking evaluator with a tier-1 stack VM on top: slot-allocated locals, frame-linked closures, object shapes, and inline caches.</FeatureCard>
<FeatureCard tag="// c-api" title="C API subset">Exports the implemented public C API surface — <code>JSGlobalContextCreate</code>, <code>JSEvaluateScript</code>, and friends — for hosts that only need that subset, without treating compatibility shims as permanent before stabilization.</FeatureCard>
<FeatureCard tag="// conformance" title="Measured, scoped">Scored against the real test262 suite with a crash-proof subprocess harness. The configured runner is green with zero skips and zero exclusions.</FeatureCard>
</div>

## Per-suite breakdown

<table class="suites"><thead><tr><th>Suite</th><th>Passing</th><th>Total</th><th>Rate</th></tr></thead><tbody>
@foreach (data.test262.suites as s)
<tr><td>test/{{ s.name }}</td><td>{{ s.passing }}</td><td>{{ s.total }}</td><td>{{ s.percentage }}%<span class="mini"><i style="width: {{ s.percentage }}%"></i></span></td></tr>
@endforeach
</tbody></table>

> Numbers come from `docs/.data/test262.json`. Regenerate them after a run with `bun run docs:data` — the homepage and conformance page update automatically.

## Where engines like this go

zig-js is built as a general embeddable JavaScript engine for Zig applications, language runtimes, tools, and hosts that want to own their JS stack. Read the [architecture](/architecture) deep-dive, the [conformance](/conformance) methodology, or the [C-API](/api) embedding guide.
