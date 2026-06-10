# SCALEBENCH — scalability of a big threaded program (JS threads vs Go vs Java)

Date: 2026-06-10. Author: scalebench run phase (Tools/threads/scalebench/SPEC.md §5).
Results JSON: `Tools/threads/scalebench/results.json` (valid: true).
Raw tables: `Tools/threads/scalebench/RESULTS.md`. Per-run artifacts: `Tools/threads/scalebench/out/`.

This document answers the question asked on the threads PR: **how does
scalability hold up on big programs that use the threads** — not
microkernels. It also reports the parallel-self criterion (linear scalability
running a program in parallel with itself, no deliberate sharing) from
`Tools/threads/scaling-gate.sh` / `JSTests/threads/scaling/`.

**Known structural handicap:** GC under JS threads on this branch is
currently stop-the-world with parallel marking; concurrent marking is
designed (SPEC-congc.md) but not implemented. Go and Java ship fully
concurrent collectors. Allocation-heavy phases (A especially) are expected to
show STW pauses scaling with heap size and thread count. Results must be
reported with this stated up front, not buried.

## 0. The honest answer, up front

On this tree, **the big-program matrix could not be completed for JS at
W >= 2**: an open shared-GC-heap correctness bug (under-marking during STW
collections with N mutators — live cells swept and re-allocated; §5)
corrupts the benchmark's shared heap and kills 41 of 42 JS runs at
W in {2..64} (uncaught corruption exceptions, SIGSEGVs, SIGABRTs). Go and
Java completed the full matrix with bit-identical checksums; JS completed
W=1 with the same checksums.

On the parallel-self suite (independent work, no deliberate sharing,
GIL-off), the picture at N <= 8 is:

| workload | character | speedup(4) | speedup(8) | notes |
|---|---|---|---|---|
| splay-like | GC-pressure tree churn | 1.47x | 1.59x | best result; its class floors are 2.0/3.0 — still VIOLATION |
| string-heavy | rope/atom churn | 1.15x | 1.14x | flat; one N=8 run died in the STW watchdog |
| map-heavy | Map alloc churn | 1.11x | 1.13x | fully GC-serialized |
| raytrace-like | FP compute + small-object churn | 0.67x | 0.65x | NEGATIVE scaling (N threads slower than 1 doing 1/N the work) |
| richards-like | OO dispatch + small objects | 0.19x | 0.23x | catastrophic negative scaling (T(2) = 15x T(1)) + STW-watchdog SIGABRTs |

So: **the threading infrastructure is functionally there** (locks, atomics,
barriers, threads; checksums at JS W=1 and the smoke runs match Go/Java
exactly; serial identity for plain flag-off code is intact), but **on this
tree the engine does not scale at all yet, on any workload in either
suite**: the best parallel-self result is 1.59x at 8 threads, two workloads
scale NEGATIVELY, and at least two open engine bugs (§5 corruption, §6.3
STW-watchdog deadlock) sit in front of any scalability work. Concurrent
marking (SPEC-congc.md) is the designed fix for the dominant GC
serialization; the negative-scaling workloads additionally point at
per-collection stop/handshake and watchpoint/STW-storm costs that grow with
N (§7).

No spin: by the design's own success criterion ("linear scalability when a
program is run in parallel with itself"), the current tree does not pass on
any of the five workloads, and the big-program benchmark is blocked on a
correctness bug before multi-thread scalability can even be measured for JS.

## 1. Machine, toolchains, binary provenance

- AWS instance, Intel Xeon Platinum 8488C (Sapphire Rapids), 1 socket,
  **64 vCPUs = 32 physical cores x 2 SMT**, 1 NUMA node, 247 GB RAM.
  W in {48, 64} is therefore SMT/oversubscription territory by hardware, not
  just scheduling.
- Kernel 6.12.68-92.122.amzn2023.x86_64, Amazon Linux 2023.10.
- Go: `go version go1.24.13 linux/amd64`.
- Java: OpenJDK 21.0.10 LTS, Corretto-21.0.10.7.1, mixed mode, sharing.
- jsc: `WebKitBuild/Release/bin/jsc` from branch `jarred/threads`, pinned
  flag set (the platform under test, not tuning):
  `--useJSThreads=1 --useThreadGIL=0 --useVMLite=1
  --useSharedAtomStringTable=1 --useSharedGCHeap=1 --useThreadGILOffUnsafe=1`.
- Build verified current with the tree before the run (`ninja jsc`: no work
  to do). **Disclosure:** a concurrent CVE-close session rebuilt the Release
  binary during the batch window (mtime 05:21:38Z at preflight, 05:29:05Z
  mid-matrix). The six js W=1 runs straddle the swap and agree within 3.7%
  (23.7-24.6 s) with identical checksums; go/java are separate runtimes and
  unaffected. The parallel-self runs (§6) all used the 05:29:05Z binary.
- JSC compiler/GC helper threads are part of the platform and are NOT
  counted in W. `cpu_util` may exceed 1.0; it is reported as-is.

Quiet-host protocol: the run phase started at 1-min loadavg **891.20**
(another workflow's build finishing) and waited until < 4 (reached 04:45Z)
before any measured run; the orphaned fuzzer processes found spinning at
100% CPU (PPID 1, WebKitBuild/Fuzz jsc, 1.5 h old) were killed first. During
the matrix the runner's own load gate added 30 s and post-run settle excess
60 s (total 90 s, under the SPEC §6 5-minute disclosure threshold). A
concurrent session ran bounded single-jsc CVE verification loops (~1 core,
intermittent) during parts of the window; this is disclosed, not hidden —
it cannot explain any of the order-of-magnitude effects reported here.

## 2. What the benchmark is (SPEC summary)

`Tools/threads/scalebench/SPEC.md`, frozen, N_BASE pinned 2026-06-10.
A concurrent in-memory inverted index over a synthetic corpus, ~300-600
lines per language, three phases in one process, all threads spawned once
and reused (hand-rolled counting barrier from Lock+Condition equivalents in
all three languages):

- **Phase A — INGEST**: 28,000 generated documents (~85-212 tokens each),
  claimed via one shared atomic counter; hand-rolled tokenizer (two
  allocations per token); per-document tf map; postings appended to
  **128 shards** of {mutex, plain hash map} — one lock acquisition per
  (doc, distinct term). Real string work, real shared-map writes, real
  contention (Zipf-skewed terms hammer hot shards).
- **Phase B — QUERY**: 28,000 ops, 90% readers (point / 2-3-term AND /
  scored top-20 against a frozen df snapshot) / 10% writers (full ingest of
  a new doc). Reader results filtered to base docs so checksums are
  timing-independent.
- **Phase C — ANALYTICS**: parallel group-by over all shards into 104
  shared groups under group locks, then top-20 per group.

All arithmetic is unsigned 64-bit (JS: BigInt masked to 64 bits — the spec
REQUIRES this; it is also what triggers the §5 engine bug's allocation
churn). splitmix64 PRNG, FNV-1a hashing, no floating point anywhere.
Five checksums (A, postings, A2, B, C) must be bit-identical across all
three languages and ALL thread counts.

### Fairness rules (binding; SPEC §2)

1. Same algorithm, same abstraction level: sharded plain hash map + plain
   mutex everywhere. Java: NO ConcurrentHashMap/StampedLock/LongAdder.
   Go: NO sync.Map, NO RWMutex, NO channels for the queue. JS: NO
   SharedArrayBuffer tricks; `Lock`, `Atomics.*` on plain object properties.
2. Idiomatic but unoptimized; no pooling/arenas/interning beyond runtime
   defaults; pinned builder-style text assembly + hand-rolled tokenizer.
3. Identical inputs/constants; runner cross-checks via JSON output.
4. Checksum gate across the whole matrix.
5. No floating point in measured code.
6. Default runtime flags (the pinned JS thread flag set is the platform
   under test and exempt). One documented exception per language allowed
   for pathological defaults — none was needed for go/java; the single
   recorded exception entry documents the §5 JS engine bug accommodation
   (an engine bug, not a flag change — no JS flags were altered).
7. W OS threads: JS `new Thread`, Go goroutines (GOMAXPROCS default),
   Java platform threads.

Matrix: W in {1, 2, 4, 8, 16, 32, 48, 64}; 1 warmup + 5 measured reps per
cell, medians; languages interleaved java,go,js per rep so drift hits all
three equally; 1-min loadavg < 4 gate before every run.

## 3. Big-program results (medians of 5; speedup vs same language W=1)

Checksums across all 103 successful runs (full go/java matrix, js W=1, plus
one surviving js W=2 rep):
`A=b3e65a6855b9bdeb, postings=4158957, A2=39c33392b2a4c5b2, B=c4bdd580f85ee058, C=af028188d7a56a96`
— bit-identical in every successful cell, all three languages. The
three-language W=1 and W=4 smoke gates (N_BASE=2000) also matched exactly
(js W=4 smoke failed with the §5 corruption; go/java W=4 matched).

### Total wall time

| W | js ms | js speedup | go ms | go speedup | java ms | java speedup |
|---|---|---|---|---|---|---|
| 1 | 24307 | 1.00x | 1771 | 1.00x | 1898 | 1.00x |
| 2 | FAILED 4/5 | — | 1070 | 1.66x | 1307 | 1.45x |
| 4 | FAILED 5/5 | — | 712 | 2.49x | 1067 | 1.78x |
| 8 | FAILED 5/5 | — | 514 | 3.45x | 956 | 1.99x |
| 16 | FAILED 5/5 | — | 402 | 4.40x | 901 | 2.11x |
| 32 | FAILED 5/5 | — | 370 | 4.79x | 1079 | 1.76x |
| 48 | FAILED 5/5 | — | 362 | 4.89x | 1047 | 1.81x |
| 64 | FAILED 5/5 | — | 386 | 4.59x | 1134 | 1.67x |

### Phase A — INGEST (allocation + shared-map writes; the GC-handicap phase)

| W | js ms | go ms | go speedup | java ms | java speedup |
|---|---|---|---|---|---|
| 1 | 15363 | 1275 | 1.00x | 1271 | 1.00x |
| 8 | — | 354 | 3.60x | 513 | 2.48x |
| 32 | — | 230 | 5.55x | 504 | 2.52x |
| 64 | — | 243 | 5.24x | 558 | 2.28x |

### Phase B — QUERY 90/10 (read-mostly)

| W | js ms | go ms | go speedup | java ms | java speedup |
|---|---|---|---|---|---|
| 1 | 2825 | 395 | 1.00x | 493 | 1.00x |
| 8 | — | 71 | 5.58x | 246 | 2.01x |
| 32 | — | 45 | 8.81x | 268 | 1.84x |
| 64 | — | 49 | 8.13x | 258 | 1.91x |

### Phase C — ANALYTICS (group-merge under shared locks)

| W | js ms | go ms | go speedup | java ms | java speedup |
|---|---|---|---|---|---|
| 1 | 127 | 14 | 1.00x | 30 | 1.00x |
| 8 | — | 11 | 1.31x | 83 | 0.36x |
| 64 | — | 12 | 1.15x | 220 | 0.14x |

(Full 8-row tables for every phase, plus min/max per cell, are in
`Tools/threads/scalebench/RESULTS.md` and `results.json`.)

### Peak RSS (MB, median) and CPU utilization

| W | js RSS | go RSS | java RSS | js cpu | go cpu | java cpu |
|---|---|---|---|---|---|---|
| 1 | 421 | 178 | 837 | 1.02 | 1.48 | 2.05 |
| 8 | — | 182 | 796 | — | 0.84 | 1.02 |
| 64 | — | 206 | 914 | — | 0.23 | 0.69 |

cpu_util = (user+sys)/(wall x W) over the FULL process lifetime (includes
JVM startup; each run's `inprogram_share` in results.json quantifies the
dilution — go ~0.97 at W=64, java ~0.90). Values > 1 at W=1 are the
runtimes' own helper threads (Java's concurrent GC most, 2.05).

### JS failure detail (the §5 bug, per cell)

Failure modes across the 40 failed JS runs (warmup + 5 reps x 7 cells, 1
W=2 rep survived): exit 3 = uncaught corruption exception (BigInt parse /
type error from a corrupted posting list), 139 = SIGSEGV, 134 = SIGABRT
(libstdc++ assertion / RELEASE_ASSERT):

| W | outcomes |
|---|---|
| 2 | 5x exit-3, 1 OK (42.2 s — 1.7x SLOWER than W=1) |
| 4 | 4x exit-3, 2x SIGSEGV |
| 8 | 2x exit-3, 4x SIGSEGV |
| 16 | 2x exit-3, 3x SIGSEGV, 1x SIGABRT |
| 32 | 1x exit-3, 1x SIGSEGV, 4x SIGABRT |
| 48 | 6x SIGABRT |
| 64 | 6x SIGABRT |

No run produced a silently-wrong checksum (the quarantine path recorded
zero hits); every corrupt run died loudly before or at its own checksum.

### What the go/java columns establish (the benchmark is sound)

- The workload scales to ~4.9x (Go) on 32 physical cores by DESIGN: hot
  Zipf terms serialize on shard locks, Phase C is a deliberate shared-append
  merge, and Phase A is allocation-bound. Go's cpu_util at W=64 is 0.23 with
  inprogram_share 0.97 — the idle time is real lock-wait, not startup. This
  is the intended "big program with contended sharing", not an
  embarrassingly-parallel strawman: a JS implementation on a sound engine
  has ~5x headroom to chase, not 64x.
- Java's plateau at ~2x (and Phase C's 0.14x backslide) is the same shape:
  HashMap+ReentrantLock per shard with biased-lock-free JDK21 monitors;
  its concurrent GC keeps Phase A at 2.5x where Go reaches 5.8x.
- JS W=1 is 12.8x slower than Go W=1 end-to-end. ~2/3 of that is the
  BigInt-based u64 arithmetic the spec mandates for checksum identity
  (every PRNG step and hash allocates a heap BigInt; Phase A is 15.4 s of
  predominantly BigInt churn vs Go's native uint64 at 1.3 s). This is a
  single-thread throughput gap, reported as-is, but it is NOT the
  scalability answer — the scalability answer for JS is blocked on §5.

## 4. SPEC §5.5 checksum gate status

- go, java: PASS at every W (all 96 runs, warmups included).
- js: PASS at W=1 (6/6 runs) and the surviving W=2 rep; remaining
  W in {2..64} runs failed before completing (no mismatching checksum was
  ever emitted — corruption is loud on this workload).
- Batch declared `valid: true` with the JS cells recorded `failed` per
  SPEC §6 and nulled medians; the single SPEC §4 "exceptions" entry
  documents the engine-bug accommodation (run.sh would otherwise have
  aborted the whole batch including the sound go/java cells — see the
  comment block above `JS_SHARED_HEAP_BUG` in run.sh).

## 5. The blocking engine bug (gates ALL JS W >= 2 results)

`Tools/threads/scalebench/js/repro-bigint-shared-ingest.js` (found by the
implementation phase; narrowed by this run phase — full status block in the
file header). Shape: 4 threads doing spec-mandated BigInt PRNG churn while
appending to Lock-protected shared posting lists corrupt the shared heap
~100% of runs at W=4 within ~2 s of work.

What this phase established (Release jsc, 2026-06-10 05:29Z binary):

- **GC-dependent**: `--useGC=0` -> clean 4/4. GC on -> corrupt ~100%.
- **Not marking parallelism**: `--numberOfGCMarkers=1` still corrupts.
- **Not generational/remembered sets**: `--useGenerationalGC=0` (full
  collections only) still corrupts; `--useConcurrentGC=0` still corrupts.
- **Live cells are being swept**: `--sweepSynchronously=1` converts the
  silent aliasing into immediate crashes. Under lazy sweep the re-allocation
  is delayed, which is why the default mode shows silent corruption.
- **Shared-heap specific**: `--useSharedGCHeap=0` (other flags kept) ->
  clean; `--useSharedAtomStringTable=0` -> still corrupts.
- **Corruption shape** (diagnostic dump): a shared array's butterfly ALIASES
  another thread's freshly-allocated Map storage — term strings and small
  counts interleaved into a docIds array, parallel arrays diverging in
  length. Consistent with a cell that was in-flight (held only in a
  mutator's registers/stack at the STW handshake) being missed by
  conservative-root/newlyAllocated accounting, swept, and re-handed to
  another thread's allocator.
- **Masked by instrumentation**: Debug build (same tree) 0/2, TSan build
  (rebuilt from this tree) 0/1 with zero TSAN reports, GIL-on 0/2 —
  Release-timing-only. TSAN will not name this one; it needs the
  hypothesis-driven treatment (thread-bughunter) with the repro above,
  which is fast and deterministic enough to bisect instrumentation into.

This is plausibly the same root cause as the parked butterfly-stress
silent-corruption case (Tools/threads/bughunt/EVIDENCE.md) — that case's
old broad signature space (cross-object aliasing) matches this shape — but
that identification is a hypothesis, not a finding.

## 6. Parallel-self suite (Pizlo's original criterion)

`Tools/threads/scaling-gate.sh` (report mode), `JSTests/threads/scaling/`:
each workload runs N threads of identical INDEPENDENT work (no deliberate
sharing); perfect scaling is speedup(N) = N x T(1) / T(N) = N. Floors (for
--gate on a quiet host): speedup(4) >= 2.8 and speedup(8) >= 4.5
(splay-like: 2.0 / 3.0).

### 6.1 As shipped (GIL-ON: the script passes only `--useJSThreads=1`)

The suite predates GIL removal; its stock invocation measures the GIL build:
map-heavy speedup(2..64) = 0.99-1.01x — textbook GIL serialization, as
designed for phase 1. Serial identity on this (noisy-window) run: T(1)
flag-on 1634.9 ms vs flag-off 1418.4 ms = +15.3% (VIOLATION vs the 5%
tolerance; see §6.4). The stock run then aborted at raytrace-like N=16,
which exceeded the default 120 s cell timeout — 16x serialized work does
not fit the budget; report-only artifact, not an engine failure.

### 6.2 GIL-OFF (pinned flag set via wrapper `Tools/threads/scalebench/out/jsc-giloff`; cell timeout 1800 s; N in {1,2,4,8})

From `scaling-gate.sh` (map-heavy, raytrace-like — medians of 3) and manual
cells with the same harness invocation for the rest (richards/string/splay:
harness-reported SCALING times, 2 runs, best shown — best-case for the
engine; the gate itself aborted at richards-like N=4 on a first attempt with
the §6.3 watchdog SIGABRT, so those three workloads' rows could not come
from a single gate run):

| workload | T(1) ms | speedup(2) | speedup(4) | speedup(8) | floors (4/8) |
|---|---|---|---|---|---|
| map-heavy | 2278 | 1.04x | 1.11x | 1.13x | 2.8 / 4.5 — VIOLATION |
| raytrace-like | 10227 | 0.68x | 0.67x | 0.65x | 2.8 / 4.5 — VIOLATION |
| richards-like | 3621 | 0.14x | 0.19x | 0.23x | 2.8 / 4.5 — VIOLATION |
| string-heavy | 2730 | 1.31x | 1.15x | 1.14x | 2.8 / 4.5 — VIOLATION |
| splay-like | 3544 | 1.21x | 1.47x | 1.59x | 2.0 / 3.0 — VIOLATION |

richards-like is the standout pathology: two threads of independent work
take 53-54 s where one takes 3.6 s (T(2) = 14.7x T(1)) — consistent with a
repeating storm of Class-A watchpoint fires each forcing a stop-the-world
(the same path that intermittently trips the §6.3 watchdog on this
workload). raytrace-like's 0.65-0.68x is the same shape at lower intensity.

An exploratory wide sweep (N up to 64) showed map-heavy flat at ~1.0-1.2x
through N=64, and raytrace-like at N=16 running at ~800% CPU while wall time
blew past 600 s — parallel execution is real (8 cores busy), but it is spent
in GC stop/start and allocator slow paths, not progress.

### 6.3 STW-watchdog deadlock (second open engine bug, distinct from §5)

richards-like at N=4 and N=8, and string-heavy at N=8, intermittently
(~1/3 of runs) die in:

```
JSThreads stop-the-world failed to reach a stopped world within 30.000000s.
Pending Class-A fire context: ... (WatchpointSet Class-A fire).
  entered lite ... tid=1 ... hasHeapAccess=true  <== NON-QUIESCENT (blocking the stop)
  entered lite ... tid=2 ... hasHeapAccess=true  <== NON-QUIESCENT (blocking the stop)
  entered lite ... tid=3 ... hasHeapAccess=true  <== NON-QUIESCENT (blocking the stop)
```

then SIGABRT. This is the watchdog family thread-ab17b/ab17e worked in,
recurring under a WatchpointSet Class-A fire with multiple non-quiescent
lites. It is a liveness release-blocker independent of §5.

### 6.4 Serial cost of the flag set (single thread, map-heavy)

Same binary, same host window: flag-off 1418 ms -> `--useJSThreads=1`
(GIL build) 1635 ms (+15.3%) -> full pinned GIL-off set 2278 ms (+60.6%
vs flag-off). The +15.3% GIL-on identity violation and the +60% GIL-off
single-thread tax on this Map-allocation-heavy workload are findings of
this run (host had ~1 intermittent background core; the bench-gate history
records +3.1% on its own workload on a quiet host — the map-heavy number
needs a quiet-host re-measure before being treated as final, but the
ordering flag-off < GIL < GIL-off-set was stable across every run today).

## 7. Analysis — where it stands, why

1. **The dominant scalability cost today is the stop-the-world GC, exactly
   as the §0 handicap statement predicts.** map-heavy (pure Map/alloc churn)
   gets ZERO parallel speedup: N threads allocate N x as fast, every
   collection stops all N, and collection work grows with live set — wall
   time grows ~linearly with N. raytrace-like and richards-like are worse
   than 1.0x: their small-object churn drives constant eden cycles whose
   stop/handshake overhead scales with N, so adding threads adds GC rounds
   faster than it adds compute. Go/Java do not pay this: their collectors
   run concurrently with mutators.
2. **Parallel execution is real but mostly wasted.** The mutator-side
   machinery does run N threads on N cores (raytrace-like N=16 was observed
   at ~800% CPU; the §3 matrix's failed JS W=4 cells ran at ~500% before
   dying), and splay-like/string-heavy show genuine if small wall-time wins
   (1.59x / 1.14x at 8). But no workload in either suite reaches even half
   its floor: the cycles go to GC stop/handshake rounds, allocator slow
   paths, and (for richards-like) what looks like a watchpoint-fire STW
   storm — richards' T(2) = 14.7x T(1) cannot be explained by GC volume
   alone and matches the §6.3 Class-A fire signature.
3. **Correctness gates scalability**: the §5 under-marking corruption makes
   every shared-write-heavy JS program unsafe at W >= 2 on this exact tree
   (the full corpus is green because its tests don't combine sustained
   BigInt-rate allocation with cross-thread shared appends at this
   intensity — this benchmark is precisely the "big program" gap the PR
   question pointed at). The §6.3 watchdog deadlock intermittently kills
   even no-sharing programs at N >= 4.
4. **Lock/atomics overhead differences are visible but second-order.** JS
   `Lock.hold` is a closure call per acquisition and `Atomics.add` on an
   object property is a runtime call; Go inlines a CAS fast path and Java
   biases to a fast monitorenter. At W=1 these show up inside the 12.8x
   single-thread gap (with BigInt churn the dominant term); at W >= 2 they
   are unmeasurable behind the GC wall.
5. **What would change the answer**: (a) fix §5 (deterministic repro in
   hand; TSAN-blind, so instrumentation-bisect or audit the in-flight-cell
   liveness chain: conservative roots of parked lites + newlyAllocated
   accounting per TLC); (b) fix §6.3 (watchdog context already names the
   Class-A fire path); (c) land SPEC-congc concurrent marking — without it,
   no allocation-heavy workload will pass the 2.8x/4.5x floors regardless
   of correctness, and the big-program matrix's Phase A will stay
   GC-bound; (d) re-run this entire document's §3 matrix. The harness,
   corpus, pinned constants and checksums are frozen and reusable as-is.

## 8. Reproduction

```
# Big-program matrix (writes results.json/RESULTS.md):
Tools/threads/scalebench/run.sh

# Engine-bug repro (~100% at W=4, ~2s):
WebKitBuild/Release/bin/jsc --useJSThreads=1 --useThreadGIL=0 --useVMLite=1 \
  --useSharedAtomStringTable=1 --useSharedGCHeap=1 --useThreadGILOffUnsafe=1 \
  Tools/threads/scalebench/js/repro-bigint-shared-ingest.js

# Parallel-self, GIL-off:
SCALING_CELL_TIMEOUT_SECS=1800 Tools/threads/scaling-gate.sh \
  --threads "1 2 4 8" Tools/threads/scalebench/out/jsc-giloff
```
