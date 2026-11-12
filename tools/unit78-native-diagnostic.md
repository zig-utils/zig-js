# Unit 78 native diagnostic

This manual workflow observes the unchanged Linux Debug+TSan unit shard. It is
diagnostic evidence, not a performance or correctness qualification.

The observer is a standalone Zig standard-library executable, built separately
from the engine. It follows the repository's native platform-tool contract and
uses no Python, shell helper, Node or additional JavaScript runtime. Its parser
tests and harmless-child fixtures also run as part of the existing dependency
audit; the Home-only migrated script inventory and audit rules stay unchanged.

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
The workflow explicitly installs the runner's distribution GDB package because
Pantry has no GDB recipe, and records its actual version. Unavailable debugging
is recorded explicitly and fails setup before starting the native workload.
Gdb disables init files, autoload
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

Exit observation uses native `waitid` without reaping. The leader's PID remains
reserved until group cleanup completes, including when it exits naturally or a
descendant closes both output handles. Cleanup gives live members up to one
second after TERM, then sends KILL if needed. Native group inspection waits for
completed exit within the two-second KILL/reap budget before reaping the leader
exactly once. The first inspection after a signal attempt is immediate; ordinary
pending-state polling remains ten milliseconds. Inspection failures and
bounded-list overflow fail cleanup rather than claiming success. Linux uses
proc group/state records; Darwin's harmless fixtures use the system libproc
interface. Original command status is preserved.

Darwin short BSD information uses the exit-aware argument so an unreaped zombie
remains visible. A completed zombie is safe even when it retains its exiting
flag. A listed member with a temporarily unavailable detail lookup or a
nonterminal exiting state keeps cleanup pending within the original deadline.
A signalable peer takes precedence over pending peers when deciding whether to
send a signal. A raced signal attempt is distinguished from a posted signal;
neither implies completed exit.

Cheap validation, with harmless children only:

    zig build unit78-native-diagnostic-test unit78-native-diagnostic
    zig-out/bin/unit78-native-diagnostic self-test
    actionlint .github/workflows/unit78-native-diagnostic.yml

The tests check evidence caps, atomic records, stat parsing with unusual process
names, marker framing, bounded child timeout and reaping, byte-preserving stream
capture, and propagation of actual exit 7 and signal failures. Harmless native
fixture modes replace interpreter-based child programs. Three cases require a
TERM-resistant nested descendant's kernel lock released before cleanup returns,
with open outputs, closed outputs and an already-exited leader. An unrelated
sentinel must remain alive throughout. The fixture records the descendant's
PID, group and start identity before cleanup. Failure cleanup can signal only
that individually revalidated descendant, never a group after its leader was
reaped. The already-exited leader also checks the production short BSD lookup's
native record size, PID, group and zombie state. Pure classifier tests separately
cover captured exiting, missing-detail and terminal states. On Linux, additional
fixtures bind an actual descendant and stderr pipe, reject stale/ambiguous
identity and refuse a dead supervisor without a result. Other hosts report
these Linux-only fixtures outside their denominator. Linux GDB availability and
native attribution still require the reviewed manual workflow.

These local controls establish observer cleanup behavior only. A Linux
cross-compilation is not a Linux runtime result. The original shard's completion,
sanitizer behavior, native attribution and backtraces require their own retained
workflow evidence; harmless fixture passes do not establish those results.

Expected observer errors go through the capped supervisor log. An unexpected
native observer crash leaves no original command result and makes collection
fail. It cannot produce an uncapped stderr artifact or imply native success.

The first hosted observation on tooling revision 89e9be1 bound the native test
and retained 24 proc samples, but GDB was absent. Its five-second sorted nm
invocation also timed out without symbol witnesses. These failures are retained;
they establish no native stack or sanitizer-symbol observation. The follow-up
installs GDB explicitly and asks nm for unsorted symbols under the same helper
budget. Engine source, full shard and all native workload limits remain fixed.
