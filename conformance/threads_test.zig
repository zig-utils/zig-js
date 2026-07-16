//! Runner for the vendored WebKit PR-249 threads corpus
//! (reference/webkit-249/threads-tests/) against the Phase-6 Thread API —
//! `zig build threads-test`. Each file runs in a fresh `enable_threads`
//! Context with the corpus's own assert.js + harness.js preloaded (their
//! `load()` becomes a no-op; the files are read from the reference tree, not
//! copied — see reference/webkit-249/README.md licensing notes).
//!
//! The allowlist below is the green set; it grows as API surface lands.
//! Files needing machinery a GIL'd tree-walker structurally lacks (some JIT/GC
//! stress, WebAssembly, and $vm hooks) stay reference-only.

const std = @import("std");
const builtin = @import("builtin");
const js = @import("js");

const corpus_root = "reference/webkit-249/threads-tests";
const isolated_case_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(240),
    .clock = .awake,
} };

const allowlist = [_][]const u8{
    "smoke.js",
    // Pulled from oven-sh/WebKit PR #249 @3a14f2a8 (2026-06-23): top-level
    // sort-comparator-shape cases, green on zig-js.
    "dw1-sort-comparator-callsite-shapes.js",
    "dw1-sort-comparator-iterator-host.js",
    "dw1-sort-comparator-osr.js",
    "api/condition-basic.js",
    "api/condition-async-wait.js",
    "api/condition-wait-termination.js",
    "api/lock-basic.js",
    "api/lock-async-hold.js",
    "api/lock-hold-termination.js",
    "api/park-no-microtask-drain.js",
    "api/thread-basic.js",
    "api/thread-ctor-errors.js",
    "api/thread-exc.js",
    "api/thread-id-bounds.js",
    "api/thread-restrict.js",
    "api/blocking-gate.js",
    "api/thread-lifecycle.js",
    "api/threadlocal-basic.js",
    "api/wasm-refused-sd7.js",
    "lifecycle/create-basics.js",
    "lifecycle/current-and-id.js",
    "lifecycle/exceptions-cross-join.js",
    "lifecycle/join-semantics.js",
    "lifecycle/nested-threads.js",
    "lifecycle/restrict.js",
    "lifecycle/restrict-foreign-access.js",
    "lifecycle/return-values.js",
    "lifecycle/async-join.js",
    "arrays/copy-on-write.js",
    "arrays/holes.js",
    "arrays/push-resize-multithread.js",
    "arrays/shared-element-read-write.js",
    "arrays/typed-arrays-sab.js",
    "bench/array-element-read.js",
    "bench/array-element-write.js",
    "bench/flat-butterfly-read.js",
    "bench/flat-butterfly-write.js",
    "bench/inline-property-read.js",
    "bench/inline-property-write.js",
    "bench/megamorphic-access.js",
    "bench/transition-heavy-constructor.js",
    "congc-t1-window-split.js",
    "cve/mc-aint-terminate-notify-park-race.js",
    "cve/mc-code-deferred-fire-stale-window.js",
    "cve/mc-code-sleep-through-jettison-isb.js",
    "cve/mc-df-delete-reuse.js",
    "cve/mc-df-segmented-length.js",
    "cve/mc-df-ta-detach-resize.js",
    "cve/mc-df-ta-sort-inplace.js",
    "cve/mc-df-wasm-compile-race.js",
    "cve/mc-dos-waiter-table-storm.js",
    "cve/mc-gc-blocked-native-roots.js",
    "cve/mc-gc-finreg-cross-thread-gc.js",
    "cve/mc-gc-thread-shell-finalizer-storm.js",
    "cve/mc-grow-s4-detach-nullvec-repro.js",
    "cve/mc-grow-wasm-relocating-grow.js",
    "cve/mc-hand-dead-registrant-settle.js",
    "cve/mc-hand-restrict-claim.js",
    "cve/mc-init-butterfly-grow-slack.js",
    "cve/mc-init-cloned-arguments-specials.js",
    "cve/mc-init-direct-arguments-override.js",
    "cve/mc-init-lazy-global-first-touch.js",
    "cve/mc-init-rope-resolve-race.js",
    "cve/mc-int-resizable-tail-quarantine.js",
    "cve/mc-jit-delete-reuse-stale-offset.js",
    "cve/mc-jit-double-relabel-stale-shape.js",
    "cve/mc-jit-ta-resize-hoisted-base.js",
    "cve/mc-life-detach-quarantine-storm.js",
    "cve/mc-life-sab-refchurn.js",
    "cve/mc-life-wasm-grow-relocate.js",
    "cve/mc-lock-cow-materialize-race.js",
    "cve/mc-lock-n3-install-vs-owner-add.js",
    "cve/mc-lock-stop-vs-park.js",
    "cve/mc-prim-arraybuffer-resize-vs-copywithin.js",
    "cve/mc-prim-arraybuffer-transfer-vs-atomics.js",
    "cve/mc-prim-async-generator-resume-claim.js",
    "cve/mc-prim-generator-claim-leak-stack-overflow.js",
    "cve/mc-prim-generator-resume-claim.js",
    "cve/mc-prim-indexed-missing-define-race.js",
    "cve/mc-reent-coercion-order.js",
    "cve/mc-reent-store-missing-indexed-define-race.js",
    "cve/mc-safe-gcwait-rope-repro.js",
    "cve/mc-safe-regexp-tts-watchdog.js",
    "cve/mc-safe-spin-vs-classa-stop.js",
    "cve/mc-tdwn-exit-vs-settle.js",
    "cve/mc-tdwn-tid-recycle-storm.js",
    "cve/mc-tdwn-vm-teardown-unjoined.js",
    "cve/mc-tear-date-cache.js",
    "cve/mc-tear-generator-resume.js",
    "cve/mc-tear-rope-resolve-race.js",
    "cve/mc-tear-typedarray-detach-grow-shrink.js",
    "cve/mc-val-atom-identity.js",
    "cve/mc-val-llint-cache-storm.js",
    "cve/mc-val-multislot-clone.js",
    "cve/mc-val-tid-reissue-false-owner.js", // PR #249 @3a14f2a8
    "cve/mc-wait-property-wait-lost-wakeup.js",
    "gc-stress/conservative-scan-register.js",
    "gc-stress/havebadtime-vs-indexed-fastpath.js",
    "gc-stress/watchpoint-storm.js",
    "gc-stress/zombie-uaf-canary.js",
    "jit/construction-shared-constructor.js",
    "jit/fires-per-sec.js",
    "jit/ftl-direct-tailcall-dataic-arg-clobber.js",
    "jit/ftl-osr-entry-catch-loop-amplifier.js",
    "jit/golden-disasm-corpus.js",
    "jit/int-gate-epoch-reclaim.js",
    "jit/int-gate-fire-vs-execute.js",
    "jit/int-gate-direct-call-relink.js",
    "jit/int-gate-jettison-vs-execute.js",
    "jit/int-gate-stop-budget.js",
    "jit/shared-arraystorage-stress.js",
    "jit/spawned-thread-butterfly-stress.js",
    "jit/tag-discipline.js",
    "jit/tid-tag-3-threads.js",
    "atomics/property-cas-delete-undefined-sentinel-u5.js",
    "atomics/property-cas-dictionary-delete-u5.js",
    "atomics/property-cas-samevaluezero.js",
    "atomics/property-cas-storm-u28-flat.js",
    "atomics/property-cas-storm-u5-as.js",
    "atomics/property-errors.js",
    "atomics/property-load-store.js",
    "atomics/property-rmw.js",
    "atomics/property-store-missing-define-race.js",
    "atomics/property-wait-notify.js",
    "atomics/property-wait-termination.js",
    "atomics/property-waitasync-timeout.js",
    "atomics/property-wtr-isolation.js",
    "atomics/ta-path-unchanged.js",
    "atomics/ta-wait-thread-gate.js",
    "sync/atomics-futex-lock.js",
    "sync/atomics-object-basic.js",
    "sync/condition-notify-all-multi-waiter.js",
    "sync/condition-notify-all-shared-lock.js",
    "sync/condition-notify-all.js",
    "sync/condition-wait-notify.js",
    "sync/condition-worker-waiter.js",
    "sync/lock-async-hold.js",
    "sync/lock-hold-basic.js",
    "sync/lock-hold-mutual-exclusion.js",
    "sync/thread-local-isolation.js",
    "shared-objects/dictionary-mode.js",
    "shared-objects/frozen-sealed.js",
    "shared-objects/getters-setters.js",
    "shared-objects/property-add.js",
    "shared-objects/property-delete.js",
    "shared-objects/property-read-write.js",
    "shared-objects/prototype-chain.js",
    "races/counter-atomics.js",
    "races/counter-lock.js",
    "races/forin-enumerator-cache.js",
    "races/join-storm.js",
    "races/transition-vs-read.js",
    "races/transition-vs-write.js",
    "races/wait-notify-storm.js",
    "heap-access-blocking.js",
    "heap-allocation-storm.js",
    "heap-bench-allocation.js",
    "heap-client-churn.js",
    "heap-deferral-storm.js",
    "heap-epoch-reclaim.js",
    "heap-iss-revert.js",
    "heap-option-off.js",
    "heap-precise-storm.js",
    "heap-stop-interleavings.js",
    "invariants/delete-quarantine-dictionary.js",
    "invariants/delete-quarantine.js",
    "invariants/no-lost-elements.js",
    "invariants/no-lost-properties-same-name.js",
    "invariants/no-lost-properties.js",
    "invariants/no-time-travel.js",
    "invariants/no-torn-shapes.js",
    "objectmodel/i03-array-resize-cas.js",
    "objectmodel/i03-as-shift-unshift.js",
    "objectmodel/i03-as-sparse-holes.js",
    "objectmodel/i03-b2-stay-flat-growth-vs-sw-flip.js",
    "objectmodel/i03-convert-grow-gc-read.js",
    "objectmodel/i03-cow-materialize-race.js",
    "objectmodel/i03-i37-same-shape-add-storm.js",
    "objectmodel/i03-n2-inline-add-races.js",
    "objectmodel/i03-n3-first-install-races.js",
    "objectmodel/i03-pa-global-races.js",
    "objectmodel/i03-quarantine-readd-across-gc.js",
    "objectmodel/i03-restart-locked-vs-conversion.js",
    "objectmodel/i03-selftest.js",
    "objectmodel/i03-shared-double.js",
    "objectmodel/i03-single-threaded-flag-on.js",
    "objectmodel/i03-single-threaded-no-change.js",
    "objectmodel/i03-stale-spine-reader-vs-grow.js",
    "objectmodel/i03-stress-force-segmented.js",
    "objectmodel/i03-stress-force-sw.js",
    "objectmodel/i03-t1-vs-sw-flip.js",
    "objectmodel/i03-t5-racing-growers.js",
    "objectmodel/i03-visit-range-outofline.js",
    "objectmodel/i08-named-vs-indexed-first-install.js",
    // Pulled from oven-sh/WebKit PR #249 @3a14f2a8 (2026-06-23): new object-model
    // cases, green on zig-js.
    "objectmodel/array-storage-property-transition.js",
    "objectmodel/cow-named-property-transition.js",
    "objectmodel/r47-foreign-dictionary-flatten.js",
    "objectmodel/r47-typedarray-slowdown-wastememory.js",
    "objectmodel/r48-typedarray-segmented-arraybuffer.js",
    "semantics/atom-rope-torture.js",
    "semantics/date-cache-churn.js",
    "semantics/frozen-seal-race.js",
    "semantics/ic-delete_by_id-vs-transition.js",
    "semantics/ic-get_by_id-vs-transition.js",
    "semantics/ic-get_by_val-vs-transition.js",
    "semantics/ic-in_by_id-vs-transition.js",
    "semantics/ic-instanceof-vs-transition.js",
    "semantics/ic-put_by_id-vs-transition.js",
    "semantics/ic-put_by_val-vs-transition.js",
    "semantics/private-fields-shared.js",
    "semantics/proto-cycle-race.js",
    "semantics/regexp-lastindex-shared.js",
    "semantics/oom-one-thread.js",
    "semantics/stack-overflow-per-thread.js",
    "semantics/symbol-registry-cross-thread.js",
    "semantics/termination-storm.js",
    "scaling/lock-fairness.js",
    "scaling/map-heavy.js",
    "scaling/raytrace-like.js",
    "scaling/richards-like.js",
    "scaling/splay-like.js",
    "scaling/string-heavy.js",
    "vmstate/all-flags-identity.js",
    "vmstate/globalthis-postpublication-negative.js", // PR #249 @3a14f2a8
    "vmstate/exception-state-per-thread.js",
    "vmstate/flags-off-baseline.js",
    "vmstate/microtask-ordering.js",
    "vmstate/regexp-churn-threads.js",
    "vmstate/stack-limits-per-thread.js",
    "vmstate/structure-churn-dictionary.js",
    "vmstate/structure-churn-threads.js",
    "vmstate/structure-lock-single-thread.js",
    "vmstate/vmlite-single-thread-identity.js",
};

const parallel_only_allowlist = [_][]const u8{
    // This witness is written for the post-ungil execution pass: under the
    // cooperative GIL the worker can starve the observer, while parallel_js
    // exercises the intended haveBadTime/checktraps park window.
    "checktraps-havebadtime-park.js",
    // Models PR-249 `--useSharedArrayBuffer=0`: Thread + property Atomics stay
    // enabled while the SAB constructor is absent. Robust only in no-GIL mode
    // because the worker counter is a timing-capability witness.
    "cve/mc-spec-timer-capability.js",
};

fn runsWithoutThreadGlobal(name: []const u8) bool {
    return std.mem.eql(u8, name, "objectmodel/i03-single-threaded-no-change.js") or
        std.mem.eql(u8, name, "vmstate/flags-off-baseline.js") or
        std.mem.eql(u8, name, "vmstate/vmlite-single-thread-identity.js");
}

fn usesBenchHarness(name: []const u8) bool {
    return (std.mem.startsWith(u8, name, "bench/") and !std.mem.endsWith(u8, name, "/harness.js")) or
        std.mem.eql(u8, name, "heap-bench-allocation.js") or
        std.mem.eql(u8, name, "jit/construction-shared-constructor.js") or
        std.mem.eql(u8, name, "jit/fires-per-sec.js");
}

fn parallelJsBudgetSkip(name: []const u8) bool {
    _ = name;
    return false;
}

fn requiresProcessIsolation(name: []const u8) bool {
    // This WeakRef/GC reclamation oracle is intentionally process-isolated in
    // the full corpus so previous stress cases cannot pin its process-global
    // heap state; focused `one` mode still exercises the JS witness directly.
    return std.mem.eql(u8, name, "cve/mc-dos-waiter-table-storm.js");
}

fn runIsolatedCase(gpa: std.mem.Allocator, io: std.Io, parallel_js: bool, name: []const u8) !bool {
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);

    const argv_parallel = [_][]const u8{ exe, "parallel-js", "one", name };
    const argv_default = [_][]const u8{ exe, "one", name };
    const argv = if (parallel_js) &argv_parallel else &argv_default;
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(4 << 20),
        .stderr_limit = .limited(4 << 20),
        .timeout = isolated_case_timeout,
    }) catch |err| {
        std.debug.print("  FAIL  {s}: isolated worker {s}\n", .{ name, @errorName(err) });
        return false;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const exited_ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) {
        std.debug.print("  FAIL  {s}: isolated worker failed\n", .{name});
        if (res.stdout.len != 0) std.debug.print("{s}", .{res.stdout});
        if (res.stderr.len != 0) std.debug.print("{s}", .{res.stderr});
        return false;
    }
    return true;
}

fn asyncDrainPolls(name: []const u8) usize {
    const base: usize = if (builtin.sanitize_thread) 30_000 else 3_000;
    if (std.mem.eql(u8, name, "cve/mc-dos-waiter-table-storm.js")) {
        // This stress case can run 2000 gc()/microtask turns after the waiter
        // storm has already settled. Whole-corpus warmed-state runs can make the
        // reclamation arm miss the default async drain even in an isolated child
        // process; give this eventual-GC oracle more normal-build turn budget
        // without raising the already-large TSan budget.
        return base * if (builtin.sanitize_thread) 6 else 30;
    }
    return base;
}

fn asyncDrainSleepMs(name: []const u8) i64 {
    if (std.mem.eql(u8, name, "cve/mc-dos-waiter-table-storm.js")) {
        // Once the arm-2 80ms timers have fired, this case is mostly a long
        // chain of Promise/GC turns. Shorter sleeps keep the runner advancing
        // the turn queue instead of spending most of its budget parked.
        return 1;
    }
    return 10;
}

fn heapLimitBytesForCase(name: []const u8) ?usize {
    // The PR-249 OOM witness's original JSC RAM-cap directive is inert in the
    // vendored file. Map it to zig-js's real Context allocator cap so the
    // promoted case exercises the same pressure contract in the normal corpus:
    // at least one Thread hits the cap, catches the reserved OutOfMemoryError,
    // and sibling Threads still complete. Keep the cap below the test's ~256MiB
    // live hoard but above runner/bootstrap overhead.
    if (std.mem.eql(u8, name, "semantics/oom-one-thread.js")) return 192 * 1024 * 1024;
    return null;
}

const CaseTiming = struct {
    name: []const u8 = "",
    ms: u64 = 0,
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn elapsedMs(start_ns: i96, end_ns: i96) u64 {
    if (end_ns <= start_ns) return 0;
    return @intCast(@divFloor(end_ns - start_ns, std.time.ns_per_ms));
}

fn recordSlowCase(slowest: []CaseTiming, name: []const u8, ms: u64) void {
    var insert_at: ?usize = null;
    for (slowest, 0..) |entry, i| {
        if (ms > entry.ms) {
            insert_at = i;
            break;
        }
    }
    const at = insert_at orelse return;
    var i = slowest.len - 1;
    while (i > at) : (i -= 1) slowest[i] = slowest[i - 1];
    slowest[at] = .{ .name = name, .ms = ms };
}

fn estimatedSerializedShardMs(name: []const u8) u64 {
    // CI-observed serialized/GIL corpus costs from the per-case shard summaries.
    // Unknown cases keep a small non-zero default so greedy assignment still
    // spreads the rest of the allowlist evenly by count.
    if (std.mem.eql(u8, name, "dw1-sort-comparator-callsite-shapes.js")) return 2_500;
    if (std.mem.eql(u8, name, "jit/tid-tag-3-threads.js")) return 252_632;
    if (std.mem.eql(u8, name, "cve/mc-val-llint-cache-storm.js")) return 190_214;
    if (std.mem.eql(u8, name, "cve/mc-tear-typedarray-detach-grow-shrink.js")) return 169_210;
    if (std.mem.eql(u8, name, "jit/spawned-thread-butterfly-stress.js")) return 137_946;
    if (std.mem.eql(u8, name, "jit/ftl-osr-entry-catch-loop-amplifier.js")) return 113_570;
    if (std.mem.eql(u8, name, "dw1-sort-comparator-osr.js")) return 104_698;
    if (std.mem.eql(u8, name, "cve/mc-df-ta-sort-inplace.js")) return 86_825;
    if (std.mem.eql(u8, name, "cve/mc-safe-gcwait-rope-repro.js")) return 78_219;
    if (std.mem.eql(u8, name, "cve/mc-df-segmented-length.js")) return 71_910;
    if (std.mem.eql(u8, name, "cve/mc-val-multislot-clone.js")) return 60_102;
    if (std.mem.eql(u8, name, "races/counter-lock.js")) return 40_418;
    if (std.mem.eql(u8, name, "scaling/richards-like.js")) return 39_083;
    if (std.mem.eql(u8, name, "dw1-sort-comparator-iterator-host.js")) return 36_761;
    if (std.mem.eql(u8, name, "bench/array-element-write.js")) return 32_636;
    if (std.mem.eql(u8, name, "scaling/string-heavy.js")) return 30_637;
    if (std.mem.eql(u8, name, "bench/flat-butterfly-write.js")) return 29_804;
    if (std.mem.eql(u8, name, "bench/inline-property-write.js")) return 28_670;
    if (std.mem.eql(u8, name, "jit/golden-disasm-corpus.js")) return 27_561;
    if (std.mem.eql(u8, name, "jit/tag-discipline.js")) return 26_216;
    if (std.mem.eql(u8, name, "bench/array-element-read.js")) return 24_550;
    if (std.mem.eql(u8, name, "bench/flat-butterfly-read.js")) return 22_313;
    if (std.mem.eql(u8, name, "gc-stress/havebadtime-vs-indexed-fastpath.js")) return 21_516;
    if (std.mem.eql(u8, name, "races/counter-atomics.js")) return 19_292;
    if (std.mem.eql(u8, name, "bench/megamorphic-access.js")) return 17_740;
    if (std.mem.eql(u8, name, "bench/inline-property-read.js")) return 15_890;
    if (std.mem.eql(u8, name, "semantics/oom-one-thread.js")) return 14_110;
    if (std.mem.eql(u8, name, "races/transition-vs-write.js")) return 12_754;
    if (std.mem.eql(u8, name, "scaling/raytrace-like.js")) return 12_234;
    if (std.mem.eql(u8, name, "jit/ftl-direct-tailcall-dataic-arg-clobber.js")) return 7_182;
    if (std.mem.eql(u8, name, "cve/mc-df-delete-reuse.js")) return 3_928;
    if (std.mem.eql(u8, name, "cve/mc-jit-delete-reuse-stale-offset.js")) return 3_908;
    if (std.mem.eql(u8, name, "cve/mc-init-butterfly-grow-slack.js")) return 2_819;
    if (std.mem.eql(u8, name, "semantics/ic-delete_by_id-vs-transition.js")) return 2_385;
    if (std.mem.eql(u8, name, "cve/mc-jit-double-relabel-stale-shape.js")) return 2_014;
    if (std.mem.eql(u8, name, "cve/mc-jit-ta-resize-hoisted-base.js")) return 1_837;
    return 1_000;
}

const WeightedShardOrder = struct {
    names: []const []const u8,

    fn lessThan(ctx: WeightedShardOrder, a: usize, b: usize) bool {
        const a_ms = estimatedSerializedShardMs(ctx.names[a]);
        const b_ms = estimatedSerializedShardMs(ctx.names[b]);
        if (a_ms != b_ms) return a_ms > b_ms;
        return std.mem.lessThan(u8, ctx.names[a], ctx.names[b]);
    }
};

fn leastLoadedShard(loads_ms: []const u64) usize {
    var best: usize = 0;
    for (loads_ms[1..], 1..) |load, shard| {
        if (load < loads_ms[best]) best = shard;
    }
    return best;
}

fn assignThreadTestShards(
    gpa: std.mem.Allocator,
    names: []const []const u8,
    assignments: []usize,
    shard_n: usize,
    weighted: bool,
) !void {
    if (!weighted) {
        for (assignments, 0..) |*assignment, case_index| {
            assignment.* = case_index % shard_n;
        }
        return;
    }

    var loads_ms = try gpa.alloc(u64, shard_n);
    defer gpa.free(loads_ms);
    @memset(loads_ms, 0);

    const order = try gpa.alloc(usize, names.len);
    defer gpa.free(order);
    for (order, 0..) |*slot, case_index| slot.* = case_index;

    std.mem.sort(usize, order, WeightedShardOrder{ .names = names }, WeightedShardOrder.lessThan);
    for (order) |case_index| {
        const shard = leastLoadedShard(loads_ms);
        assignments[case_index] = shard;
        loads_ms[shard] += estimatedSerializedShardMs(names[case_index]);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    // `zig build threads-test -Dthreads-sweep=true` runs every default-gate
    // directory file instead of the green allowlist (a panicking file kills the run — use
    // `-Dthreads-case=<path>` to probe a single file safely).
    var parallel_js = false;
    var sweep = false;
    var list_mode = false;
    var one: ?[]const u8 = null;
    var shard_index: ?usize = null;
    var shard_count: ?usize = null;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "parallel-js")) {
            parallel_js = true;
            continue;
        }
        if (std.mem.eql(u8, a, "sweep")) sweep = true;
        if (std.mem.eql(u8, a, "list")) list_mode = true;
        if (std.mem.eql(u8, a, "one")) one = args.next();
        if (std.mem.eql(u8, a, "shard")) {
            const raw_index = args.next() orelse {
                std.debug.print("threads-test: shard requires <index> <count>\n", .{});
                return error.InvalidShard;
            };
            const raw_count = args.next() orelse {
                std.debug.print("threads-test: shard requires <index> <count>\n", .{});
                return error.InvalidShard;
            };
            shard_index = std.fmt.parseInt(usize, raw_index, 10) catch {
                std.debug.print("threads-test: invalid shard index '{s}'\n", .{raw_index});
                return error.InvalidShard;
            };
            shard_count = std.fmt.parseInt(usize, raw_count, 10) catch {
                std.debug.print("threads-test: invalid shard count '{s}'\n", .{raw_count});
                return error.InvalidShard;
            };
        }
    }
    const shard_n = shard_count orelse 1;
    const shard_i = shard_index orelse 0;
    if (shard_n == 0 or shard_i >= shard_n) {
        std.debug.print("threads-test: invalid shard {d}/{d}\n", .{ shard_i, shard_n });
        return error.InvalidShard;
    }

    // `list`: print the green allowlist (one path per line) and exit, so a
    // driver (CI's whole-corpus no-GIL TSan sweep) can run each entry in its own
    // process via `threads-test parallel-js one <path>` — per-case isolation that
    // sidesteps the cumulative-load OOM of a single all-in-one-process TSan run.
    if (list_mode) {
        for (allowlist) |name| std.debug.print("{s}\n", .{name});
        if (parallel_js) for (parallel_only_allowlist) |name| std.debug.print("{s}\n", .{name});
        return;
    }

    var dir = cwd.openDir(io, corpus_root, .{}) catch {
        std.debug.print("threads-test: corpus not found at {s} (run from the repo root)\n", .{corpus_root});
        return error.CorpusMissing;
    };
    defer dir.close(io);

    const assert_src = try dir.readFileAlloc(io, "resources/assert.js", gpa, .limited(1 << 20));
    defer gpa.free(assert_src);
    const harness_src = try dir.readFileAlloc(io, "harness.js", gpa, .limited(1 << 20));
    defer gpa.free(harness_src);
    const bench_harness_src = try dir.readFileAlloc(io, "bench/harness.js", gpa, .limited(1 << 20));
    defer gpa.free(bench_harness_src);
    const scaling_harness_src = try dir.readFileAlloc(io, "scaling/harness.js", gpa, .limited(1 << 20));
    defer gpa.free(scaling_harness_src);
    const vmstate_workload_src = try dir.readFileAlloc(io, "vmstate/resources/workload.js", gpa, .limited(1 << 20));
    defer gpa.free(vmstate_workload_src);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        if (sweep) for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    const explicit_one = one != null;
    if (sweep) {
        for ([_][]const u8{ "api", "arrays", "atomics", "bench", "lifecycle", "races", "scaling", "shared-objects", "sync" }) |sub| {
            var d = dir.openDir(io, sub, .{ .iterate = true }) catch continue;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".js")) continue;
                if (std.mem.eql(u8, entry.name, "harness.js")) continue;
                const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, entry.name });
                try names.append(gpa, full);
            }
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
    } else if (one) |paths| {
        var it = std.mem.splitScalar(u8, paths, ',');
        while (it.next()) |path| {
            if (path.len != 0) try names.append(gpa, path);
        }
    } else {
        try names.appendSlice(gpa, &allowlist);
        if (parallel_js) try names.appendSlice(gpa, &parallel_only_allowlist);
    }

    const weighted_shards = shard_count != null and shard_n > 1 and !parallel_js and !sweep and !explicit_one;
    const shard_assignments = try gpa.alloc(usize, names.items.len);
    defer gpa.free(shard_assignments);
    try assignThreadTestShards(gpa, names.items, shard_assignments, shard_n, weighted_shards);

    var selected_total: usize = 0;
    var selected_estimated_ms: u64 = 0;
    for (names.items, 0..) |name, case_index| {
        if (shard_assignments[case_index] == shard_i) {
            selected_total += 1;
            selected_estimated_ms += estimatedSerializedShardMs(name);
        }
    }
    if (shard_count != null) {
        if (weighted_shards) {
            std.debug.print(
                "threads-test: shard {d}/{d} selected {d}/{d} corpus files (weighted estimate {d} ms)\n",
                .{ shard_i, shard_n, selected_total, names.items.len, selected_estimated_ms },
            );
        } else {
            std.debug.print(
                "threads-test: shard {d}/{d} selected {d}/{d} corpus files\n",
                .{ shard_i, shard_n, selected_total, names.items.len },
            );
        }
    }

    var failed: usize = 0;
    var skipped: usize = 0;
    var completed: usize = 0;
    var shard_started_ns: i96 = 0;
    var slowest = [_]CaseTiming{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    if (shard_count != null) shard_started_ns = nowNs(io);
    for (names.items, 0..) |name, case_index| {
        if (shard_assignments[case_index] != shard_i) continue;
        const case_started_ns = nowNs(io);
        completed += 1;
        std.debug.print("  RUN   {d}/{d} {s}\n", .{ completed, selected_total, name });
        if (parallel_js and !explicit_one and parallelJsBudgetSkip(name)) {
            skipped += 1;
            const case_ms = elapsedMs(case_started_ns, nowNs(io));
            recordSlowCase(&slowest, name, case_ms);
            std.debug.print("  SKIP  {s} ({d} ms, parallel_js budget frontier)\n", .{ name, case_ms });
            continue;
        }
        if (!explicit_one and !sweep and requiresProcessIsolation(name)) {
            const passed = try runIsolatedCase(gpa, io, parallel_js, name);
            const case_ms = elapsedMs(case_started_ns, nowNs(io));
            recordSlowCase(&slowest, name, case_ms);
            if (passed) {
                std.debug.print("  PASS  {s} ({d} ms)\n", .{ name, case_ms });
            } else {
                failed += 1;
                std.debug.print("  FAIL  {s} ({d} ms)\n", .{ name, case_ms });
            }
            continue;
        }
        // Keep corpus cases hermetic: defers in this block run at the end of
        // each file, so completed JS threads are OS-joined and all per-context
        // waiter tables/buffers are released before the next file starts.
        {
            const test_src = dir.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch {
                const case_ms = elapsedMs(case_started_ns, nowNs(io));
                recordSlowCase(&slowest, name, case_ms);
                std.debug.print("  MISS  {s} ({d} ms)\n", .{ name, case_ms });
                failed += 1;
                continue;
            };
            defer gpa.free(test_src);

            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(gpa);
            // Their `load(path)` becomes a no-op: everything it would pull in is
            // concatenated below in dependency order. asyncTestStart/Passed are
            // jsc-shell builtins in their setup; the shim counts and the runner
            // verifies the balance after the drain tail.
            try buf.appendSlice(gpa,
                \\const load = () => {};
                \\globalThis.__asyncExpected = null;
                \\globalThis.__asyncPassed = 0;
                \\globalThis.__asyncPassedLabels = [];
                \\const asyncTestStart = (n) => { globalThis.__asyncExpected = n; };
                \\const asyncTestPassed = (label) => {
                \\  globalThis.__asyncPassed++;
                \\  if (label !== undefined) globalThis.__asyncPassedLabels.push(String(label));
                \\};
                \\
            );
            // Time-dilation factor for wall-clock waits (harness `waitUntil`,
            // stress `Atomics.wait` timeouts). ThreadSanitizer slows execution
            // ~10×, so a GC-storm-vs-park rendezvous tuned for the native runtime
            // can blow its fixed timeout under the cumulative load of the whole
            // corpus in one process. Tests multiply their timeouts by this so the
            // *oracle* (the park must overlap the storm) is preserved while the
            // patience scales to the build.
            try buf.appendSlice(gpa, if (builtin.sanitize_thread)
                "globalThis.__timeScale = 10;\n"
            else
                "globalThis.__timeScale = 1;\n");
            try buf.appendSlice(gpa, assert_src);
            try buf.appendSlice(gpa, "\n");
            try buf.appendSlice(gpa, harness_src);
            try buf.appendSlice(gpa, "\n");
            if (usesBenchHarness(name)) {
                try buf.appendSlice(gpa, bench_harness_src);
                try buf.appendSlice(gpa, "\n");
                try buf.appendSlice(gpa,
                    \\// Runner-local bench sizing: the external bench gate owns
                    \\// timings; the default corpus checks deterministic results.
                    \\reportBench = function(name, fn, expected) {
                    \\  var measured = fn();
                    \\  if (measured != expected) throw "Error: bad result during benchmark of " + name + ": " + measured;
                    \\  print("BENCH " + name + " 0.000");
                    \\};
                    \\
                );
            }
            if (std.mem.startsWith(u8, name, "scaling/") and !std.mem.endsWith(u8, name, "/harness.js")) {
                try buf.appendSlice(gpa, scaling_harness_src);
                try buf.appendSlice(gpa, "\n");
            }
            if (std.mem.startsWith(u8, name, "vmstate/") and std.mem.indexOf(u8, test_src, "resources/workload.js") != null) {
                try buf.appendSlice(gpa, vmstate_workload_src);
                try buf.appendSlice(gpa, "\n");
            }
            try buf.appendSlice(gpa, test_src);

            // Per-file configs, mirroring their run-tests.sh / //@ runDefault
            // lines: blocking-gate runs can-block-is-false; thread-id-bounds runs
            // --maxJSThreads=4; *-termination runs --watchdog=500 with the
            // termination throw as its PASSING outcome.
            const directive = test_src[0 .. std.mem.indexOfScalar(u8, test_src, '\n') orelse test_src.len];
            const enable_threads = !runsWithoutThreadGlobal(name);
            const heap_limit_bytes = heapLimitBytesForCase(name);
            const options = js.Context.TestingOptions{
                .enable_threads = enable_threads,
                .enable_gc = heap_limit_bytes != null or parallel_js or std.mem.indexOf(u8, test_src, "gc()") != null,
                .parallel_gc = parallel_js and enable_threads,
                .parallel_js = parallel_js and enable_threads,
                .main_can_block = !std.mem.endsWith(u8, name, "blocking-gate.js"),
                .max_js_threads = if (std.mem.endsWith(u8, name, "thread-id-bounds.js")) 4 else null,
                .enable_shared_array_buffer = std.mem.indexOf(u8, directive, "--useSharedArrayBuffer=0") == null,
                .heap_limit_bytes = heap_limit_bytes,
            };
            const expect_termination = std.mem.endsWith(u8, name, "-termination.js") or
                std.mem.indexOf(u8, directive, "--watchdog-exception-ok") != null;
            const ctx = js.Context.createWithTestingOptions(gpa, options) catch {
                const case_ms = elapsedMs(case_started_ns, nowNs(io));
                recordSlowCase(&slowest, name, case_ms);
                std.debug.print("  FAIL  {s} ({d} ms, context)\n", .{ name, case_ms });
                failed += 1;
                continue;
            };
            defer ctx.destroy();

            // The 500ms watchdog: arms a stop flag the engine's park quanta and
            // step checkpoints poll (the engine's termination request).
            var stop = std.atomic.Value(bool).init(false);
            var watchdog: ?std.Thread = null;
            if (expect_termination) {
                ctx.stop_flag = &stop;
                const Dog = struct {
                    fn run(flag: *std.atomic.Value(bool)) void {
                        std.Io.sleep(js.agent.engineIo(), .fromMilliseconds(500), .awake) catch {};
                        flag.store(true, .monotonic);
                    }
                };
                watchdog = std.Thread.spawn(.{}, Dog.run, .{&stop}) catch null;
            }
            defer if (watchdog) |w| w.join();
            if (ctx.evaluate(buf.items)) |_| {
                if (expect_termination) {
                    const case_ms = elapsedMs(case_started_ns, nowNs(io));
                    recordSlowCase(&slowest, name, case_ms);
                    failed += 1;
                    std.debug.print("  FAIL  {s} ({d} ms): returned normally under termination\n", .{ name, case_ms });
                    continue;
                }
                var balanced = false;
                const drain_sleep_ms = asyncDrainSleepMs(name);
                for (0..asyncDrainPolls(name)) |_| {
                    const status = ctx.evaluate("$drainRunLoop(); drainMicrotasks(); __asyncExpected === null || __asyncPassed >= __asyncExpected") catch js.Value.undef();
                    if (status.isBoolean() and status.asBool()) {
                        balanced = true;
                        break;
                    }
                    std.Io.sleep(js.agent.engineIo(), .fromMilliseconds(drain_sleep_ms), .awake) catch {};
                }
                const case_ms = elapsedMs(case_started_ns, nowNs(io));
                recordSlowCase(&slowest, name, case_ms);
                if (balanced) {
                    std.debug.print("  PASS  {s} ({d} ms)\n", .{ name, case_ms });
                } else {
                    const progress = ctx.evaluate("String(__asyncPassed) + '/' + String(__asyncExpected)") catch js.Value.undef();
                    const progress_s = if (progress.isString()) progress.asStr() else "?/?";
                    failed += 1;
                    std.debug.print("  FAIL  {s} ({d} ms): async completions not reached ({s})\n", .{ name, case_ms, progress_s });
                    const labels = ctx.evaluate("__asyncPassedLabels.join(',')") catch js.Value.undef();
                    if (labels.isString() and labels.asStr().len != 0)
                        std.debug.print("  completed async arms: {s}\n", .{labels.asStr()});
                    const arm3 = ctx.evaluate("typeof __arm3Turn === 'number' ? String(__arm3Cleared) + '/128 after ' + String(__arm3Turn) + ' turns' : ''") catch js.Value.undef();
                    if (arm3.isString() and arm3.asStr().len != 0)
                        std.debug.print("  arm3 reclamation progress: {s}\n", .{arm3.asStr()});
                    if (std.mem.eql(u8, name, "cve/mc-dos-waiter-table-storm.js")) {
                        if (ctx.gc) |heap| std.debug.print(
                            "  GC cycles: full={d}, minor={d}; request pending={}\n",
                            .{ heap.full_collections, heap.minor_collections, ctx.gc_requested.load(.monotonic) },
                        );
                        if (ctx.gil) |g| {
                            g.lockPropWaiters();
                            const pending_prop_async = g.prop_async.items.len;
                            g.unlockPropWaiters();
                            std.debug.print("  pending property async tickets: {d}\n", .{pending_prop_async});
                        }
                        var not_exited: usize = 0;
                        for (ctx.js_threads.items) |rec| {
                            rec.join_mutex.lockUncancelable(js.agent.engineIo());
                            if (!rec.exited) not_exited += 1;
                            rec.join_mutex.unlock(js.agent.engineIo());
                        }
                        std.debug.print("  thread records not exited: {d}\n", .{not_exited});
                    }
                    if (ctx.print_buffer.items.len != 0) {
                        std.debug.print("{s}", .{ctx.print_buffer.items});
                        if (ctx.print_buffer.items[ctx.print_buffer.items.len - 1] != '\n') std.debug.print("\n", .{});
                    }
                }
            } else |eval_err| {
                const case_ms = elapsedMs(case_started_ns, nowNs(io));
                recordSlowCase(&slowest, name, case_ms);
                if (expect_termination) {
                    // The watchdog-exception-ok contract: the termination throw IS
                    // the pass; the D9-violation paths print FAILURE first.
                    if (std.mem.indexOf(u8, ctx.print_buffer.items, "FAILURE") == null) {
                        std.debug.print("  PASS  {s} ({d} ms)\n", .{ name, case_ms });
                    } else {
                        failed += 1;
                        std.debug.print("  FAIL  {s} ({d} ms): D9 violated\n", .{ name, case_ms });
                    }
                    continue;
                }
                if (ctx.exception) |e| {
                    if (e.isString() and std.mem.eql(u8, e.asStr(), "__zigjs_threads_quit__")) {
                        std.debug.print("  PASS  {s} ({d} ms)\n", .{ name, case_ms });
                        continue;
                    }
                }
                failed += 1;
                // Stringifying the exception can run JS (Error.prototype.toString):
                // hold the GIL like any other entry into the realm.
                if (ctx.gil) |g| g.acquire();
                defer if (ctx.gil) |g| g.release();
                if (ctx.exception) |e| {
                    var machine = ctx.interpreter();
                    if (machine.toStringV(e)) |msg| {
                        std.debug.print("  FAIL  {s} ({d} ms, {s}): {s}\n", .{
                            name, case_ms, @errorName(eval_err), msg,
                        });
                    } else |stringify_err| {
                        const exception_kind = if (e.isObject() and e.asObj().behavior.is_error and e.asObj().errorName().len != 0)
                            e.asObj().errorName()
                        else
                            e.typeOf();
                        // This fallback is allocation-free and does not invoke
                        // user JavaScript, so it remains useful under the exact
                        // heap pressure that made ToString fail.
                        std.debug.print("  FAIL  {s} ({d} ms, {s}): exception={s}, stringify={s}\n", .{
                            name, case_ms, @errorName(eval_err), exception_kind, @errorName(stringify_err),
                        });
                    }
                } else {
                    std.debug.print("  FAIL  {s} ({d} ms, {s}): exception=<missing>\n", .{
                        name, case_ms, @errorName(eval_err),
                    });
                }
            }
        }
    }
    if (shard_count != null) {
        std.debug.print("threads-test: shard {d}/{d} elapsed {d} ms\n", .{ shard_i, shard_n, elapsedMs(shard_started_ns, nowNs(io)) });
        std.debug.print("threads-test: shard {d}/{d} slowest cases:\n", .{ shard_i, shard_n });
        for (slowest) |entry| {
            if (entry.name.len == 0) break;
            std.debug.print("  {d} ms  {s}\n", .{ entry.ms, entry.name });
        }
    }
    std.debug.print("------------------------\n{d}/{d} corpus files passed", .{ selected_total - failed - skipped, selected_total });
    if (skipped != 0) std.debug.print(" ({d} skipped)", .{skipped});
    std.debug.print("\n", .{});
    if (failed != 0 and !sweep) return error.CorpusFailures;
}
