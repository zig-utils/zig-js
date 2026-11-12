# Unit 78 native diagnostic

This manual workflow observes the unchanged Linux Debug+TSan unit shard. It is
diagnostic evidence, not a performance or correctness qualification.

The workflow checks out engine revision
b42c2c8fd93ba61b9ed7d9acd3c9a5663bb2efd6 separately from the observer tooling.
Its compiler, Pantry action, sibling sources, default optimization, Home path
environment and command match that revision's TSan unit shard 1 gate:

    zig build test -Dtsan=true -Dunit-shard-index=1 -Dunit-shard-count=4

The full shard still runs. No fixture, callback count, test selection, allocator,
GC setting, sanitizer setting or compiler source is modified. Main CI is
untouched. The job retains its 60-minute timeout.

The supervisor owns the build command in a separate process group. It binds the
complete case 78 start marker to a unique descendant executable named test
whose stderr writes the observed pipe, then records its PID, process start
ticks, arguments and executable SHA256. Start ticks are checked before subsequent
observations. It also records observed Zig compiler invocations and TSan symbol
witnesses. Missing or ambiguous identity is recorded as a diagnostic failure,
not guessed.

Before starting the shard, a harmless owned sleep child tests gdb attach,
backtrace and detach. The observer tries ordinary gdb first, then noninteractive
sudo gdb when available. It never changes ptrace, kernel or sanitizer settings.
Unavailable debugging is recorded explicitly. Gdb disables init files, autoload
and debuginfod. Captures use frame-arguments none, no entry values, no locals
and no memory dumps. Neither process environments nor arbitrary process
arguments are collected.

For 120 seconds after the marker, the observer records process/thread CPU
ticks, RSS pages, state and wait channel every five seconds. At offsets 10, 60
and 110 seconds it requests all-thread backtraces, with at most 32 frames per
thread. Each helper has a five-second execution budget plus at most three
seconds for termination and reaping. Actual elapsed time, failures and output
truncation are recorded. The native process continues afterward.

The collection step uploads when the observation completes, the original
command exits, or 40 minutes after the first job step, whichever comes first.
The original command continues while early artifacts upload. A subsequent step
awaits and propagates the original exit status, including signal failures.
Terminal artifacts are attempted when the command completes. A later whole-job
timeout can prevent terminal upload, but the early upload already ran. Setup or
runner failures before collection can still prevent an early artifact.

Evidence is capped below 10 MiB: 6 MiB raw merged output, 1 MiB proc records,
512 KiB compiler invocation records, 64 KiB supervisor log, and a fixed inventory
of at most 13 control records of 64 KiB each. Atomic replacement can temporarily
add one further 64 KiB file. Backtraces are capped to 8 KiB each before JSON
encoding. Raw stream bytes are preserved up to the stated cap; later truncation
does not stop or shorten the workload. No native binaries are uploaded.

If the supervisor fails unexpectedly, the collector fails instead of reporting
the original shard successful. Supervisor termination cleans up its owned
command group. GitHub's normal job cleanup remains responsible for the detached
supervisor at whole-job termination; its runner tracking environment is retained.

Cheap validation, with harmless children only:

    python3 tools/unit78-native-diagnostic.py self-test
    actionlint .github/workflows/unit78-native-diagnostic.yml

The self-test checks evidence caps, atomic records, Linux stat parsing with
unusual process names, bounded child timeout and reaping, byte-preserving stream
capture, and propagation of an actual child exit status 7. Linux debugger
availability and native attribution remain untested until the reviewed manual
workflow runs.
