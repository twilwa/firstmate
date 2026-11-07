#!/usr/bin/env python3
"""Private v1 SSH worker for fm-test-remote.py; not a standalone test launcher.

The supervisor owns cancellation, flock(2) slot mutexes and directory lifetime.
Each slot also has an atomic, durable owner record. Losing a supervisor or failing
cleanup never clears that reservation: the next mutex holder must reconcile the
prior scope and orphaned runs before claiming the slot or launching a replacement.
Only the scope child restores snapshots and executes tests; no uncapped fallback.
"""
import fcntl
import json
import os
import re
from pathlib import Path
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import time
import uuid


class Cancelled(Exception):
    pass


def note(message):
    print("fm-test-remote: " + message, file=sys.stderr, flush=True)


def lock(path, nonblocking=False):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
    except BaseException:
        os.close(fd)
        raise
    return fd


def scope_name(run):
    return "fm-test-remote-" + run.name + ".scope"


def active(unit):
    result = subprocess.run(["systemctl", "--user", "show", "--property=ActiveState", "--value", unit],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True, timeout=5)
    state = result.stdout.strip()
    if state not in {"active", "activating", "deactivating", "reloading", "inactive", "failed"}:
        raise RuntimeError("cannot establish scope state: " + unit)
    return state not in {"inactive", "failed"}


def stop_scope(unit):
    # Never kill by pattern or account; this unit is named by our own run UUID.
    if active(unit):
        note("stopping scope " + unit)
        subprocess.run(["systemctl", "--user", "kill", "--signal=KILL", "--kill-whom=all", unit],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=5)
        for _ in range(50):
            if not active(unit):
                note("stopped scope " + unit)
                return
            time.sleep(0.1)
        raise RuntimeError("scope did not stop; retaining its run directory")


def reap(root):
    """Called under policy.lock, including after a queued slot mutex is acquired."""
    for old in (root / "runs").iterdir():
        if old.is_symlink() or not old.is_dir() or not re.fullmatch(r"r[0-9a-f]{32}", old.name):
            raise ValueError("unexpected entry in runs directory")
        try:
            lease = lock(old / "lease", True)
        except BlockingIOError:
            continue
        try:
            stop_scope(scope_name(old))
            shutil.rmtree(old)
            note("reaped abandoned run " + old.name)
        finally:
            os.close(lease)


def slot_owner(path):
    if path.is_symlink():
        raise ValueError("invalid slot owner")
    if not path.exists():
        return None
    owner = path.read_text()
    if not re.fullmatch(r"r[0-9a-f]{32}", owner):
        raise ValueError("invalid slot owner")
    return owner


def claim_slot(root, run, slot):
    guard = lock(root / "policy.lock")
    try:
        owner_file = root / f"slot-{slot}.owner"
        previous = slot_owner(owner_file)
        if previous is not None:
            # The slot mutex is ours, but the durable reservation may belong to
            # a scope whose supervisor died or failed cleanup. Never launch
            # alongside it, even if that supervisor still holds its run lease.
            stop_scope(scope_name(root / "runs" / previous))
        reap(root)
        pending = run / "slot-owner"
        pending.write_text(run.name)
        os.replace(pending, owner_file)
    finally:
        os.close(guard)


def initialize(root, config):
    runs = root / "runs"
    runs.mkdir(mode=0o700, exist_ok=True)
    if runs.is_symlink():
        raise ValueError("unsafe runs directory")
    guard = lock(root / "policy.lock")
    try:
        reap(root)
        policy = {key: config[key] for key in ("slots", "cpu_percent", "memory_mb", "tasks_max", "port_base", "port_count")}
        policy_file = root / "policy.json"
        if policy_file.exists() and json.loads(policy_file.read_text()) != policy and any(runs.iterdir()):
            raise ValueError("resource/port policy changed while runs are active; wait for them to finish")
        policy_file.write_text(json.dumps(policy))
        run = runs / ("r" + uuid.uuid4().hex)
        run.mkdir(mode=0o700)
        lease = lock(run / "lease", True)
        return run, lease
    finally:
        os.close(guard)


def safe_unpack(archive, destination, allowed=None):
    with tarfile.open(archive) as source:
        for member in source:
            name = Path(member.name)
            if name.is_absolute() or ".." in name.parts or ".git" in name.parts:
                raise ValueError("unsafe snapshot path")
            if allowed is not None and (member.name not in allowed or not member.isfile()):
                raise ValueError("unexpected snapshot member")
            target = destination / name
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError("snapshot path escapes run directory")
            if not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError("unsupported snapshot member")
            if member.issym() and not (target.parent / member.linkname).resolve().is_relative_to(destination.resolve()):
                raise ValueError("untracked symlink escapes test tree")
            # Paths and symlink targets have been checked without trusting tar's
            # version-dependent extraction filter defaults.
            source.extract(member, destination, filter="fully_trusted")


def execute(run):
    """Executed ONLY by systemd-run, inside all configured cgroup limits."""
    cgroup = Path("/proc/self/cgroup").read_text().split("0::", 1)[1].strip()
    if scope_name(run) not in Path(cgroup).parts or run.parent != Path(__file__).resolve().parent / "runs":
        raise ValueError("scope child must run in its own capped unit and private run directory")
    counters = Path("/sys/fs/cgroup") / cgroup.lstrip("/")
    limits = json.loads((run / "limits.json").read_text())
    quota, period = (counters / "cpu.max").read_text().split()
    if (quota == "max" or int(quota) * 100 > limits["cpu"] * int(period)
            or int((counters / "memory.max").read_text()) > limits["memory"] * 1024**2
            or int((counters / "memory.swap.max").read_text()) != 0
            or int((counters / "pids.max").read_text()) > limits["tasks"]):
        raise ValueError("required cgroup limits were not applied")
    (run / "started").touch()

    def events():
        values = {}
        for name in ("memory.events", "pids.events"):
            for line in (counters / name).read_text().splitlines():
                key, value = line.split()
                values[name + ":" + key] = int(value)
        return values

    before = events()
    payload = run / "payload"
    payload.mkdir()
    safe_unpack(run / "request.tar", payload,
                {"head.bundle", "changes.patch", "untracked.tar", "request.json"})
    request = json.loads((payload / "request.json").read_text())
    tree = run / "tree"
    home = run / "home"
    home.mkdir()
    temporary = run / "tmp"
    temporary.mkdir()
    env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(temporary),
           "LANG": "C.UTF-8", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
    git = ["git", "-c", "core.hooksPath=/dev/null"]
    subprocess.run([*git, "clone", "--quiet", "--no-checkout", str(payload / "head.bundle"), str(tree)], env=env, check=True)
    subprocess.run([*git, "-C", str(tree), "checkout", "--quiet", "--detach", request["head"]], env=env, check=True)
    if (payload / "changes.patch").stat().st_size:
        subprocess.run([*git, "-C", str(tree), "apply", "--binary", str(payload / "changes.patch")], env=env, check=True)
    safe_unpack(payload / "untracked.tar", tree)
    cwd = (tree / request["cwd"]).resolve()
    if not cwd.is_relative_to(tree):
        raise ValueError("test working directory escapes snapshot")
    assignment = json.loads((run / "assignment.json").read_text())
    env.update(FM_REMOTE_RUN_ID=run.name, FM_REMOTE_RUN_DIR=str(run),
               FM_REMOTE_PORT_MIN=str(assignment["port_min"]), FM_REMOTE_PORT_MAX=str(assignment["port_max"]),
               FM_REMOTE_DB_SUFFIX="_" + run.name, FM_REMOTE_SLOT=str(assignment["slot"]))
    note(f"running {run.name} slot={assignment['slot']} ports={assignment['port_min']}-{assignment['port_max']}")
    result = subprocess.run(request["command"], cwd=cwd, env=env, stdin=subprocess.DEVNULL)
    code = result.returncode if result.returncode >= 0 else 128 - result.returncode
    after = events()
    capped = [key for key in ("memory.events:oom_kill", "pids.events:max") if after[key] > before[key]]
    (run / "result.json").write_text(json.dumps(dict(kind="command", code=code, cap_events=capped)))
    return 0


def supervise(header, root):
    config = header["config"]
    run = None
    lease = None
    slot_fd = None
    slot_claimed = False
    child = None
    outcome = dict(kind="setup", code=126)
    control = selectors.DefaultSelector()
    control.register(sys.stdin.fileno(), selectors.EVENT_READ)

    def cancelled(wait=0):
        if control.select(wait):
            raise Cancelled()

    def signal_cancel(signum, frame):
        raise Cancelled()

    signal.signal(signal.SIGTERM, signal_cancel)
    signal.signal(signal.SIGINT, signal_cancel)
    signal.signal(signal.SIGHUP, signal_cancel)
    try:
        run, lease = initialize(root, config)
        note("receiving " + run.name)
        remaining = header["archive_size"]
        if not 0 < remaining <= 20 * 1024**3:
            raise ValueError("invalid snapshot size (maximum 20 GiB)")
        with (run / "request.tar").open("wb") as target:
            while remaining:
                block = sys.stdin.buffer.read(min(1024 * 1024, remaining))
                if not block:
                    raise Cancelled()
                target.write(block)
                remaining -= len(block)
        deadline = time.monotonic() + config["queue_timeout"]
        note(f"slot-wait-start {run.name} at={time.time():.6f} slots={config['slots']}")
        while slot_fd is None:
            for slot in range(config["slots"]):
                try:
                    slot_fd = lock(root / ("slot-" + str(slot) + ".lock"), True)
                except BlockingIOError:
                    continue
                break
            if slot_fd is None:
                if time.monotonic() >= deadline:
                    outcome = dict(kind="queue-timeout", code=124)
                    return outcome
                cancelled(0.1)
        claim_slot(root, run, slot)
        slot_claimed = True
        note(f"slot-acquired {run.name} at={time.time():.6f} slot={slot}")
        cancelled()
        port_min = config["port_base"] + slot * config["port_count"]
        sockets = []
        try:
            for port in range(port_min, port_min + config["port_count"]):
                sock = socket.socket()
                sockets.append(sock)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind(("127.0.0.1", port))
        finally:
            for sock in sockets:
                sock.close()
        (run / "assignment.json").write_text(json.dumps(dict(slot=slot, port_min=port_min,
                                                             port_max=port_min + config["port_count"] - 1,
                                                             supervisor_pid=os.getpid())))
        # Read the timeout from the small, validated request member, without
        # restoring/executing anything until inside the scope.
        with tarfile.open(run / "request.tar") as archive:
            request = json.load(archive.extractfile("request.json"))
        timeout = request["timeout"]
        if type(timeout) is not int or not 1 <= timeout <= config["timeout"]:
            raise ValueError("invalid execution timeout")
        cpu = config["cpu_percent"] // config["slots"]
        memory = config["memory_mb"] // config["slots"]
        tasks = config["tasks_max"] // config["slots"]
        (run / "limits.json").write_text(json.dumps(dict(cpu=cpu, memory=memory, tasks=tasks)))
        properties = [f"CPUQuota={cpu}%", f"MemoryMax={memory}M", "MemorySwapMax=0",
                      f"TasksMax={tasks}", f"RuntimeMaxSec={timeout}"]
        argv = ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--unit=" + scope_name(run)]
        for prop in properties:
            argv.extend(["-p", prop])
        argv.extend(["--", sys.executable, str(Path(__file__).resolve()), "--execute", str(run)])
        note(f"scope {run.name} cpu={cpu}% memory={memory}MiB tasks={tasks} timeout={timeout}s")
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL)
        start = time.monotonic()
        while child.poll() is None:
            cancelled(0.1)
            if time.monotonic() - start > timeout + 5:
                # Bounded cleanup even if the manager fails to enforce runtime.
                stop_scope(scope_name(run))
                break
        code = child.wait(timeout=10)
        if (run / "result.json").exists():
            outcome = json.loads((run / "result.json").read_text())
        elif code == 0:
            raise RuntimeError("scope exited without a test result")
        else:
            # Starting a scope can itself fail (no delegation/manager/property).
            # Only a child that actually started can have hit a resource cap.
            setup = (run / "setup-error").exists() or not (run / "started").exists()
            outcome = dict(kind="setup" if setup else "cap-kill", code=126 if setup else 137)
        return outcome
    except Cancelled:
        outcome = dict(kind="cancelled", code=130)
        return outcome
    except Exception as error:
        note(str(error))
        return outcome
    finally:
        # Ignore repeated interrupts while performing bounded, unit-specific
        # cleanup. The slot stays locked until every test descendant is gone.
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        reservation_cleared = False
        cleanup_guard = None
        try:
            if run is not None:
                cleanup_guard = lock(root / "policy.lock")
                stop_scope(scope_name(run))
                if child is not None and child.poll() is None:
                    child.wait(timeout=10)
                # A launcher observed before scope creation may finish later;
                # verify termination again before clearing its reservation.
                stop_scope(scope_name(run))
                if slot_claimed:
                    owner_file = root / f"slot-{slot}.owner"
                    if slot_owner(owner_file) != run.name:
                        raise RuntimeError("slot owner changed before cleanup")
                    owner_file.unlink()
                    reservation_cleared = True
                shutil.rmtree(run)
        except Exception as error:
            note("cleanup failed; preserving run: " + str(error))
            outcome.update(kind="cleanup", code=126)
        finally:
            if cleanup_guard is not None:
                os.close(cleanup_guard)
            if slot_fd is not None:
                # The kernel mutex is not the reservation. A failed cleanup
                # retains its durable owner even when this process exits; the
                # next mutex holder must prove the prior scope is gone first.
                released = time.time()
                os.close(slot_fd)
                if reservation_cleared:
                    note(f"slot-released {run.name} at={released:.6f} slot={slot}")
                elif slot_claimed:
                    note(f"slot-reserved {run.name} slot={slot}; scope cleanup not confirmed")
            if lease is not None:
                os.close(lease)
            control.close()
        note("result " + json.dumps(outcome))
        print("FM_TEST_RESULT_" + header["nonce"] + " " + json.dumps(outcome), file=sys.stderr, flush=True)


if __name__ == "__main__":
    if "_HEADER" in globals():
        supervise(_HEADER, Path(sys.argv[1]).resolve())
    elif len(sys.argv) == 3 and sys.argv[1] == "--execute":
        directory = Path(sys.argv[2])
        try:
            sys.exit(execute(directory))
        except Exception as error:
            (directory / "setup-error").write_text(str(error))
            note("snapshot/test setup failed: " + str(error))
            sys.exit(126)
    else:
        sys.exit("use fm-test-remote.py; this is its private scope worker")
