#!/usr/bin/env python3
"""Run tests from an isolated task worktree on a capped SSH worker.

Usage: bin/fm-test-remote.py [--timeout SECONDS] -- COMMAND [ARG ...]
Uses this home's config/remote-test.json (see docs/configuration.md). No shell
expansion is applied to COMMAND; pass bash -c explicitly when needed. Stdout and
stderr stream live over one strict-host-key SSH connection. Ctrl-C/disconnect
cancels the generated remote scope and removes its run directory.

Normal test exit codes are preserved, including 255, even when the command
survived a memory OOM kill or PIDs-limit event; the typed result lists those
events in cap_events. Infrastructure outcomes also print a typed result: 124
queue timeout, 125 transport/unreported setup, 126 setup/cleanup failure, 130
cancellation, 137 scope killed at a cap before reporting a command status. A
test may itself return one of these codes; the typed result disambiguates it.
--timeout covers snapshot restoration and execution, not upload or the bounded
queue; it may shorten but never raise the home's runtime cap. FM_SSH_BIN
selects an explicit SSH executable for transport tests; it never changes PATH.
"""
import argparse
import hashlib
import json
import os
import re
import secrets
import shlex
import subprocess
from pathlib import Path
import sys
import tarfile
import tempfile
import threading

# Fixed bootstrap: install only content-addressed worker bytes, then hand the
# same buffered input stream to that worker (including its cancellation EOF).
BOOTSTRAP = r'''
import hashlib, json, os, pathlib, sys
header = json.loads(sys.stdin.buffer.readline(65536))
root = pathlib.Path(sys.argv[1])
if root.is_symlink() or not root.is_absolute() or root == pathlib.Path('/'):
    raise ValueError('unsafe remote root')
root.mkdir(mode=0o700, parents=True, exist_ok=True)
if root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o077:
    raise ValueError('remote root must be owned by this account and mode 0700')
size = header['worker_size']
if not 0 < size <= 262144: raise ValueError('invalid worker size')
code = sys.stdin.buffer.read(size)
digest = hashlib.sha256(code).hexdigest()
if digest != header['worker_sha256']: raise ValueError('worker checksum mismatch')
worker = root / ('worker-v1-' + digest + '.py')
staged = root / ('worker-v1-' + digest + '.' + os.urandom(8).hex() + '.tmp')
with os.fdopen(os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as target: target.write(code)
os.replace(staged, worker)
if worker.is_symlink() or hashlib.sha256(worker.read_bytes()).hexdigest() != digest:
    raise ValueError('installed worker checksum mismatch')
exec(compile(code, str(worker), 'exec'), {'__name__':'__main__', '__file__':str(worker), '_HEADER':header})
'''


def configuration(path):
    with path.open() as source:
        config = json.load(source)
    if not isinstance(config, dict):
        raise ValueError("remote-test.json must be a JSON object")
    required = {"host", "user", "identity_file", "known_hosts_file", "remote_root"}
    defaults = dict(cpu_percent=400, memory_mb=8192, tasks_max=512, slots=1,
                    timeout=900, queue_timeout=300, port_base=20000, port_count=100)
    unknown = config.keys() - required - defaults.keys()
    if unknown:
        raise ValueError(f"unknown remote-test.json fields: {', '.join(sorted(unknown))}")
    for field in required:
        if not isinstance(config.get(field), str) or not config[field]:
            raise ValueError(f"remote-test.json requires {field}")
    for field in ("host", "user"):
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", config[field]):
            raise ValueError(f"invalid {field}")
    for field in ("identity_file", "known_hosts_file"):
        config[field] = str(Path(config[field]).expanduser().resolve(strict=True))
        if not Path(config[field]).is_file():
            raise ValueError(f"{field} must name a file")
    root = config["remote_root"]
    if not root.startswith("/") or root == "/" or ".." in Path(root).parts or "\n" in root:
        raise ValueError("remote_root must be a dedicated absolute directory, not /")
    for field, default in defaults.items():
        value = config.setdefault(field, default)
        if type(value) is not int or not 1 <= value <= 1000000:
            raise ValueError(f"{field} must be a positive integer <= 1000000")
    if (config["slots"] > 32 or config["cpu_percent"] < config["slots"]
            or config["memory_mb"] < 64 * config["slots"] or config["tasks_max"] < config["slots"]):
        raise ValueError("slots must be <=32 with at least 1% CPU, 64 MiB and one task per slot")
    if config["port_base"] < 1024 or config["port_base"] + config["slots"] * config["port_count"] > 65536:
        raise ValueError("port ranges must fit in unprivileged TCP ports")
    return config


def git(*args, cwd=None):
    return subprocess.check_output(["git", *args], cwd=cwd).decode().strip()


def task_root():
    root = Path(git("rev-parse", "--show-toplevel")).resolve()
    primary = git("worktree", "list", "--porcelain", "-z").split("\0", 1)[0]
    if not primary.startswith("worktree ") or Path(primary[9:]).resolve() == root:
        raise ValueError("refusing a primary checkout; run from an isolated task worktree")
    return root


def snapshot(root, directory, request):
    if git("submodule", "status", cwd=root):
        raise ValueError("submodules are not supported by the remote snapshot")
    bundle = directory / "head.bundle"
    subprocess.run(["git", "-c", "pack.threads=1", "bundle", "create", str(bundle), "HEAD"], cwd=root, check=True)
    patch = subprocess.check_output(["git", "diff", "--binary", "HEAD", "--"], cwd=root)
    (directory / "changes.patch").write_bytes(patch)
    names = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root)
    with tarfile.open(directory / "untracked.tar", "w") as archive:
        for name in names.split(b"\0"):
            if name:
                path = os.fsdecode(name)
                archive.add(root / path, arcname=path, recursive=False)
    request["head"] = git("rev-parse", "HEAD", cwd=root)
    (directory / "request.json").write_text(json.dumps(request))
    payload = directory / "request.tar"
    with tarfile.open(payload, "w") as archive:
        for name in ("head.bundle", "changes.patch", "untracked.tar", "request.json"):
            archive.add(directory / name, arcname=name)
    return payload


def transport(config, payload):
    worker = Path(__file__).with_name("fm-test-remote-worker.py").read_bytes()
    nonce = secrets.token_hex(16)
    header = dict(worker_size=len(worker), worker_sha256=hashlib.sha256(worker).hexdigest(),
                  archive_size=payload.stat().st_size, nonce=nonce, config=config)
    command = "python3 -c " + shlex.quote(BOOTSTRAP) + " " + shlex.quote(config["remote_root"])
    ssh = [os.environ.get("FM_SSH_BIN", "ssh"), "-T", "-o", "BatchMode=yes",
           "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
           "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=10",
           "-o", "ServerAliveCountMax=3", "-o", "ForwardAgent=no",
           "-o", "ClearAllForwardings=yes", "-i", config["identity_file"],
           "-o", "UserKnownHostsFile=" + config["known_hosts_file"],
           config["user"] + "@" + config["host"], command]
    tail = bytearray()
    process = subprocess.Popen(ssh, stdin=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)

    def forward_errors():
        while True:
            data = os.read(process.stderr.fileno(), 65536)
            if not data:
                return
            sys.stderr.buffer.write(data)
            sys.stderr.buffer.flush()
            tail.extend(data)
            del tail[:-8192]

    reader = threading.Thread(target=forward_errors, daemon=True)
    reader.start()
    interrupted = False
    try:
        process.stdin.write(json.dumps(header).encode() + b"\n")
        process.stdin.write(worker)
        with payload.open("rb") as source:
            while block := source.read(1024 * 1024):
                process.stdin.write(block)
        process.stdin.flush()
        # Keep the control channel open. Remote EOF means cancel, including
        # when this client is killed or SSH disconnects.
        process.wait()
    except KeyboardInterrupt:
        interrupted = True
    except BrokenPipeError:
        pass
    finally:
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        reader.join(timeout=5)
        process.stderr.close()
    if interrupted:
        return 130
    marker = ("FM_TEST_RESULT_" + nonce + " ").encode()
    for line in reversed(bytes(tail).splitlines()):
        if line.startswith(marker):
            outcome = json.loads(line[len(marker):])
            return outcome["code"]
    print("fm-test-remote: transport or remote setup failed (no completed result)", file=sys.stderr)
    return 125


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--timeout", type=int, help="remote execution limit in seconds")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    home = Path(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or Path(__file__).resolve().parent.parent)
    config_path = Path(os.environ.get("FM_CONFIG_OVERRIDE") or home / "config") / "remote-test.json"
    if not config_path.exists():
        parser.error(f"{config_path} not configured; see docs/configuration.md")
    try:
        config = configuration(config_path)
        root = task_root()
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not command:
            raise ValueError("a test command is required after --")
        timeout = args.timeout if args.timeout is not None else config["timeout"]
        if not 1 <= timeout <= config["timeout"]:
            raise ValueError("--timeout must be positive and no larger than the configured timeout")
        request = dict(command=command, timeout=timeout, cwd=str(Path.cwd().resolve().relative_to(root)))
        with tempfile.TemporaryDirectory(prefix="fm-test-remote-") as directory:
            payload = snapshot(root, Path(directory), request)
            return transport(config, payload)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    sys.exit(main())
