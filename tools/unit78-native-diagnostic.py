#!/usr/bin/env python3
"""External Linux-only observer. It does not change the native test or its limits."""

import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import time

SOURCE = "b42c2c8fd93ba61b9ed7d9acd3c9a5663bb2efd6"
FIXTURE = "926b8dd424cdbb6edbc82a12605d5165b750d386fb97387a6044e643a4e0ad2b"
COMMAND = ["zig", "build", "test", "-Dtsan=true", "-Dunit-shard-index=1", "-Dunit-shard-count=4"]
CASE = b"context.test.captured frames: mapped canonical strings survive heap recovery"
MARKER = b"UNIT_TEST_STARTED\t78/721\t1/4\t" + CASE
MIB = 1024 * 1024
CAPS = {"run.log": 6 * MIB, "proc.jsonl": MIB, "build-processes.jsonl": MIB // 2,
        "supervisor.log": 65536}


class DiagnosticLog:
    def __init__(self, root):
        self.root = root

    def write(self, text):
        append(self.root, "supervisor.log", text.encode(errors="replace"))
        return len(text)

    def flush(self):
        pass


def save(root, name, value):
    """Small control records are atomically replaced, never appended."""
    data = (json.dumps(value, sort_keys=True) + "\n").encode()
    if len(data) > 65536:
        raise ValueError("control record exceeded 64KiB")
    temp = root / (name + ".tmp")
    temp.write_bytes(data)
    temp.replace(root / name)


def append(root, name, data):
    cap = CAPS.get(name, 128 * 1024)
    path = root / name
    size = path.stat().st_size if path.exists() else 0
    remaining = max(0, cap - size)
    if remaining:
        with path.open("ab", buffering=0) as handle:
            handle.write(data[:remaining])


def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(MIB), b""):
            digest.update(block)
    return digest.hexdigest()


def stat_record(pid, base=Path("/proc")):
    # comm may itself contain spaces and parentheses.
    raw = (base / str(pid) / "stat").read_text()
    fields = raw[raw.rfind(")") + 2:].split()
    return {"pid": int(pid), "state": fields[0], "ppid": int(fields[1]),
            "user_ticks": int(fields[11]), "system_ticks": int(fields[12]),
            "start_ticks": int(fields[19]), "rss_pages": int(fields[21])}


def same_process(identity):
    try:
        current = stat_record(identity["pid"])
        return current["state"] != "Z" and current["start_ticks"] == identity["start_ticks"]
    except (OSError, ValueError, KeyError):
        return False


def stop_group(child):
    """Only signal a process group created by this observer."""
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=2)


def bounded_command(args, seconds=5, cap=4096, witnesses=()):
    started = time.monotonic()
    child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
    output = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + seconds
    timed_out = False
    found = set()
    suffix = b""
    try:
        while selector.get_map():
            if time.monotonic() >= deadline:
                timed_out = True
                stop_group(child)
                break
            for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                block = os.read(key.fileobj.fileno(), 4096)
                if not block:
                    selector.unregister(key.fileobj)
                else:
                    output.extend(block[:max(0, cap - len(output))])
                    scan = suffix + block
                    found.update(word for word in witnesses if word.encode() in scan)
                    suffix = scan[-64:]
        if child.poll() is None:
            child.wait(timeout=max(0.01, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        timed_out = True
        stop_group(child)
    finally:
        selector.close()
        child.stdout.close()
        if child.poll() is None:
            stop_group(child)
    return {"args": args, "exit": child.returncode, "timed_out": timed_out,
            "output_capped": len(output) == cap, "witnesses": sorted(found),
            "elapsed_seconds": time.monotonic() - started, "output": output.decode(errors="replace")}


def gdb_args(prefix, pid):
    return prefix + ["--batch", "--nx", "--nh",
                     "-iex", "set auto-load off", "-iex", "set debuginfod enabled off",
                     "-ex", "set pagination off", "-ex", "set confirm off",
                     "-ex", "set print frame-arguments none",
                     "-ex", "set print entry-values no",
                     "-ex", "attach " + str(pid),
                     "-ex", "thread apply all bt 32", "-ex", "detach", "-ex", "quit"]


def debugger_probe(root):
    debugger = shutil.which("gdb")
    if not debugger:
        save(root, "debugger-probe.json", {"available": False, "reason": "gdb absent"})
        return None
    child = subprocess.Popen(["sleep", "30"], start_new_session=True)
    attempts = []
    try:
        identity = stat_record(child.pid)
        prefixes = [[debugger]]
        if shutil.which("sudo"):
            prefixes.append(["sudo", "-n", debugger])
        for prefix in prefixes:
            result = bounded_command(gdb_args(prefix, child.pid))
            attempts.append(result)
            # A failed attach can still cause gdb batch mode to exit zero.
            success = (result["exit"] == 0 and not result["timed_out"]
                       and "#0 " in result["output"] and "detached" in result["output"].lower())
            if same_process(identity):
                os.kill(child.pid, signal.SIGCONT)
            if success:
                save(root, "debugger-probe.json", {"available": True, "attempts": attempts})
                return prefix
        save(root, "debugger-probe.json", {"available": False, "attempts": attempts})
        return None
    finally:
        stop_group(child)


def owned_processes(child):
    records = {}
    for path in Path("/proc").iterdir():
        if path.name.isdecimal():
            try:
                record = stat_record(int(path.name))
                records[record["pid"]] = record
            except (OSError, ValueError):
                pass
    descendants = {child.pid}
    for _ in range(len(records)):
        found = {pid for pid, rec in records.items() if rec["ppid"] in descendants}
        expanded = descendants | found
        if expanded == descendants:
            break
        descendants = expanded
    return {pid: records[pid] for pid in descendants if pid in records}


def target_for_marker(child, pipe_inode):
    """Bind marker to the unique descendant native test writing this pipe."""
    records = owned_processes(child)
    candidates = []
    for pid in records.keys() - {child.pid}:
        try:
            exe = os.readlink("/proc/" + str(pid) + "/exe")
            stderr = os.stat("/proc/" + str(pid) + "/fd/2")
            if Path(exe).name == "test" and stderr.st_ino == pipe_inode:
                candidates.append({**records[pid], "executable": exe,
                                   "args": Path("/proc/" + str(pid) + "/cmdline").read_bytes()
                                   .decode(errors="replace").rstrip("\0").split("\0")})
        except (OSError, KeyError):
            pass
    if len(candidates) != 1:
        raise RuntimeError("marker requires one owned native test PID, found " + str(len(candidates)))
    identity = candidates[0]
    identity["binary_sha256"] = sha("/proc/" + str(identity["pid"]) + "/exe")
    if not same_process(identity):
        raise RuntimeError("test exited while binding executable")
    return identity


def capture_build_processes(root, child, seen):
    for pid, record in owned_processes(child).items():
        try:
            exe = os.readlink("/proc/" + str(pid) + "/exe")
            if Path(exe).name != "zig":
                continue
            raw = Path("/proc/" + str(pid) + "/cmdline").read_bytes()
            identity = (pid, record["start_ticks"], hashlib.sha256(raw).hexdigest())
            if identity in seen or len(seen) == 64:
                continue
            seen.add(identity)
            append(root, "build-processes.jsonl", (json.dumps({
                **record, "executable": exe,
                "args": raw.decode(errors="replace").rstrip("\0").split("\0"),
            }) + "\n").encode())
        except OSError:
            pass


def proc_sample(identity):
    if not same_process(identity):
        return {"elapsed_process": "exited"}
    pid = identity["pid"]
    root = Path("/proc") / str(pid)
    record = stat_record(pid)
    record["threads"] = []
    for path in sorted((root / "task").iterdir()):
        try:
            thread = stat_record(int(path.name), root / "task")
            thread["wchan"] = (path / "wchan").read_text().strip()
            record["threads"].append(thread)
        except (OSError, ValueError):
            pass
        if len(record["threads"]) == 256:
            record["threads_capped"] = True
            break
    return record


def supervise(root):
    root.mkdir(parents=True, exist_ok=True)
    if sys.platform != "linux":
        raise RuntimeError("native observation requires Linux /proc")
    revision = bounded_command(["git", "rev-parse", "HEAD"])["output"].strip()
    fixture = sha("src/fixtures/array-map-canonical-pressure.js")
    compiler = bounded_command(["zig", "version"])
    if revision != SOURCE or fixture != FIXTURE or compiler["output"].strip() != "0.18.0-dev.146+35accc06e":
        raise RuntimeError("engine source, fixture or compiler identity mismatch")
    save(root, "manifest.json", {
        "diagnostic_only": True, "source": revision, "fixture_sha256": fixture,
        "command": COMMAND, "compiler": compiler, "host": list(os.uname()),
        "clock_ticks_per_second": os.sysconf("SC_CLK_TCK"),
        "page_bytes": os.sysconf("SC_PAGE_SIZE"), "evidence_limit_bytes": 10 * MIB,
        "observation_seconds": 120, "backtrace_offsets_seconds": [10, 60, 110],
        "warning": "External debugger pauses add overhead. This is not elapsed-time qualification.",
    })
    debugger = debugger_probe(root)
    observe(root, COMMAND, debugger)


def observe(root, command, debugger, state_reader=stat_record, scan_builds=True):
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
    save(root, "state.json", {"supervisor": state_reader(os.getpid()), "command": state_reader(child.pid)})
    interrupted = []
    def interrupt(signum, _frame):
        interrupted.append(signum)
    old_handlers = {}
    for signum in (signal.SIGTERM, signal.SIGINT):
        old_handlers[signum] = signal.getsignal(signum)
        signal.signal(signum, interrupt)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    tail = b""
    target = None
    observed_at = None
    next_sample = 0
    captures = 0
    ready = False
    next_build_scan = 0
    seen_builds = set()
    try:
        while selector.get_map() or child.poll() is None:
            if interrupted:
                stop_group(child)
                break
            if scan_builds and observed_at is None and time.monotonic() >= next_build_scan:
                capture_build_processes(root, child, seen_builds)
                next_build_scan = time.monotonic() + 1
            for key, _ in selector.select(0.1):
                block = os.read(key.fileobj.fileno(), 65536)
                if not block:
                    selector.unregister(key.fileobj)
                    continue
                append(root, "run.log", block)
                tail += block
                while b"\n" in tail:
                    line, tail = tail.split(b"\n", 1)
                    if line == MARKER and observed_at is None:
                        observed_at = time.monotonic()
                        try:
                            target = target_for_marker(child, os.fstat(child.stdout.fileno()).st_ino)
                            save(root, "target.json", target)
                            symbols = bounded_command(["nm", "--defined-only", target["executable"]],
                                                      cap=0, witnesses=("__tsan_init", "__tsan_read", "__tsan_write"))
                            save(root, "symbol-command.json", symbols)
                        except (OSError, RuntimeError) as error:
                            save(root, "target-error.json", {"error": str(error)})
                tail = tail[-65536:]
            if observed_at is not None and not ready:
                elapsed = time.monotonic() - observed_at
                if target and elapsed >= next_sample and elapsed < 120:
                    try:
                        append(root, "proc.jsonl", (json.dumps({"elapsed_seconds": elapsed,
                               **proc_sample(target)}) + "\n").encode())
                    except (OSError, ValueError) as error:
                        save(root, "proc-error.json", {"error": str(error)})
                    next_sample += 5
                if target and captures < 3 and elapsed >= (10, 60, 110)[captures]:
                    capture = {"elapsed_seconds": elapsed, "available": bool(debugger)}
                    if debugger and same_process(target):
                        try:
                            capture["debugger"] = bounded_command(gdb_args(debugger, target["pid"]), cap=8192)
                        except OSError as error:
                            capture["error"] = str(error)
                        finally:
                            if same_process(target):
                                os.kill(target["pid"], signal.SIGCONT)
                    else:
                        capture["reason"] = "debugger unavailable or target exited"
                    save(root, "backtrace-" + str(captures + 1) + ".json", capture)
                    captures += 1
                if elapsed >= 120:
                    save(root, "ready.json", {"reason": "observation window complete", "target_bound": bool(target)})
                    ready = True
        status = child.wait()
        save(root, "result.json", {"exit": status, "interrupted": interrupted, "target_bound": bool(target)})
        if not ready:
            save(root, "ready.json", {"reason": "command exited", "target_bound": bool(target)})
    finally:
        selector.close()
        child.stdout.close()
        if child.poll() is None:
            stop_group(child)
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)


def echo_new(root, offset):
    path = root / "run.log"
    if path.exists():
        with path.open("rb") as handle:
            handle.seek(offset)
            data = handle.read()
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        offset += len(data)
    return offset


def monitor(root, collect):
    collection_deadline = int(os.environ.get("UNIT78_JOB_STARTED_SECONDS", str(int(time.time())))) + 2400
    offset = 0
    while True:
        offset = echo_new(root, offset)
        if collect and (root / "ready.json").exists():
            return 0
        if (root / "result.json").exists():
            status = json.loads((root / "result.json").read_text())["exit"]
            return 0 if collect else min(255, status if status >= 0 else 128 - status)
        state_path = root / "state.json"
        if state_path.exists() and not same_process(json.loads(state_path.read_text())["supervisor"]):
            raise RuntimeError("supervisor died without original command result")
        if collect and time.time() >= collection_deadline:
            save(root, "early-upload.json", {"reason": "40-minute job observation cutoff; original command continues"})
            return 0
        time.sleep(0.25)


def start(root):
    root.mkdir(parents=True, exist_ok=False)
    with (root / "supervisor.log").open("wb") as log:
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_supervise", str(root)],
                         stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True)
    for _ in range(450):
        if (root / "state.json").exists():
            return
        time.sleep(0.1)
    raise RuntimeError("supervisor startup failed; inspect supervisor.log")


def self_test():
    import tempfile
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        append(root, "run.log", b"x" * (7 * MIB))
        assert (root / "run.log").stat().st_size == 6 * MIB
        save(root, "test.json", {"safe": True})
        assert json.loads((root / "test.json").read_text()) == {"safe": True}
        mock = root / "123"
        mock.mkdir()
        fields = ["S", "1"] + ["0"] * 20
        fields[11], fields[12], fields[19], fields[21] = "12", "13", "19", "21"
        (mock / "stat").write_text("123 (a strange ) name) " + " ".join(fields))
        assert stat_record(123, root)["start_ticks"] == 19
        result = bounded_command([sys.executable, "-c", "import time; print('owned', flush=True); time.sleep(30)"], 0.2)
        assert result["timed_out"] and result["exit"] != 0 and result["output"] == "owned\n"
        result = bounded_command([sys.executable, "-c", "print('x' * 1000000)"], cap=99)
        assert result["exit"] == 0 and len(result["output"]) == 99
        assert result["output_capped"]
        sentinel = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            result = bounded_command(["sleep", "30"], 0.1)
            assert result["timed_out"] and sentinel.poll() is None
        finally:
            stop_group(sentinel)
        stream = root / "stream"
        stream.mkdir()
        observe(stream, [sys.executable, "-c",
                         "import sys; sys.stdout.write('prefix'); sys.stdout.flush(); "
                         "sys.stderr.write('suffix\\n'); sys.exit(7)"], None,
                state_reader=lambda pid: {"pid": pid, "start_ticks": 0}, scan_builds=False)
        assert (stream / "run.log").read_bytes() == b"prefixsuffix\n"
        assert json.loads((stream / "result.json").read_text())["exit"] == 7
        assert monitor(stream, False) == 7
        killed = root / "killed"
        killed.mkdir()
        observe(killed, [sys.executable, "-c",
                        "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"], None,
                state_reader=lambda pid: {"pid": pid, "start_ticks": 0}, scan_builds=False)
        assert monitor(killed, False) == 128 + signal.SIGTERM
    print("Observer self-test passed: caps, proc parsing, owned-only cleanup, streams and exit/signal status.")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "self-test":
        self_test()
    else:
        evidence = Path(sys.argv[2]).resolve()
        if mode == "start":
            start(evidence)
        elif mode == "_supervise":
            sys.stdout = sys.stderr = DiagnosticLog(evidence)
            supervise(evidence)
        elif mode in ("collect", "wait"):
            sys.exit(monitor(evidence, mode == "collect"))
        else:
            raise ValueError("unknown mode: " + mode)
