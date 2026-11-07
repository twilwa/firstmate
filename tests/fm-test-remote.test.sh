#!/usr/bin/env bash
# Focused public CLI regression; no SSH or account changes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if FM_HOME="$TMP" python3 "$ROOT/bin/fm-test-remote.py" -- true >"$TMP/out" 2>"$TMP/err"; then
  echo 'unconfigured runner unexpectedly succeeded' >&2; exit 1
fi
if ! grep -q 'remote-test.json.*not configured' "$TMP/err"; then
  echo 'missing actionable unconfigured diagnostic' >&2; exit 1
fi
printf 'PASS remote runner refuses an unconfigured home\n'
FM_HOME="$TMP" bash "$ROOT/bin/fm-brief.sh" remote-off sample --mode local-only --tests focused >/dev/null
if grep -q fm-test-remote.py "$TMP/data/remote-off/brief.md"; then
  echo 'unconfigured home received remote testing instructions' >&2; exit 1
fi
mkdir -p "$TMP/state"
promote_scout() {  # <task-id>
  FM_HOME="$TMP" bash "$ROOT/bin/fm-brief.sh" "$1" sample --scout >/dev/null
  sed -i.bak -e 's/{TASK}/Fix the widget./' -e 's/{FIRSTMATE_SPEC}/Inspect the widget./' "$TMP/data/$1/brief.md"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$1" > "$TMP/state/$1.meta"
  FM_HOME="$TMP" bash "$ROOT/bin/fm-promote.sh" "$1" --mode no-mistakes --yolo off >/dev/null 2>&1
}
promote_scout remote-promote-off
if grep -q fm-test-remote.py "$TMP/data/remote-promote-off/ship-instructions.md"; then
  echo 'unconfigured home promotion received remote testing instructions' >&2; exit 1
fi
mkdir -p "$TMP/config" "$TMP/repo"
printf '{}\n' > "$TMP/config/remote-test.json"
if FM_HOME="$TMP" python3 "$ROOT/bin/fm-test-remote.py" -- true >"$TMP/out" 2>"$TMP/err"; then
  echo 'malformed configuration unexpectedly accepted' >&2; exit 1
fi
grep -q 'remote-test.json requires' "$TMP/err"
printf 'PASS malformed configuration is actionable\n'
printf '[]\n' > "$TMP/config/remote-test.json"
if FM_HOME="$TMP" python3 "$ROOT/bin/fm-test-remote.py" -- true >"$TMP/out" 2>"$TMP/err"; then
  echo 'non-object configuration unexpectedly accepted' >&2; exit 1
fi
grep -q 'remote-test.json must be a JSON object' "$TMP/err"
printf 'PASS non-object configuration is actionable\n'
printf '' > "$TMP/key"; printf '' > "$TMP/known_hosts"
python3 - "$TMP" <<'PY'
import json, pathlib, socket, sys
p = pathlib.Path(sys.argv[1])
with socket.socket() as probe:
    probe.bind(('127.0.0.1', 0))
    port = probe.getsockname()[1]
(p / 'config/remote-test.json').write_text(json.dumps(dict(host='example.invalid', user='tests', identity_file=str(p/'key'), known_hosts_file=str(p/'known_hosts'), remote_root=str(p/'remote'), tasks_max=64, port_base=port, port_count=1)))
PY
git -C "$TMP/repo" init -q
if (cd "$TMP/repo" && FM_HOME="$TMP" python3 "$ROOT/bin/fm-test-remote.py" -- true) >"$TMP/out" 2>"$TMP/err"; then
  echo 'primary checkout unexpectedly accepted' >&2; exit 1
fi
grep -q 'primary checkout' "$TMP/err"
printf 'PASS primary checkout is rejected before transport\n'
if (cd "$TMP/repo" && FM_HOME="$TMP/absent" FM_CONFIG_OVERRIDE="$TMP/config" python3 "$ROOT/bin/fm-test-remote.py" -- true) >"$TMP/out" 2>"$TMP/err"; then
  echo 'primary checkout unexpectedly accepted with config override' >&2; exit 1
fi
grep -q 'primary checkout' "$TMP/err"
if python3 "$ROOT/bin/fm-test-remote-worker.py" --execute "$TMP" >"$TMP/out" 2>"$TMP/err"; then
  echo 'worker unexpectedly executed outside its capped private scope' >&2; exit 1
fi
grep -q 'own capped unit' "$TMP/err"
printf 'PASS config override and uncapped worker refusal\n'
for mode in no-mistakes direct-PR local-only; do
  FM_HOME="$TMP" bash "$ROOT/bin/fm-brief.sh" "remote-$mode" sample --mode "$mode" --tests focused >/dev/null
  test "$(grep -c 'fm-test-remote.py' "$TMP/data/remote-$mode/brief.md")" -eq 1
  grep -q 'browser journeys, full server partitions, repeat loops' "$TMP/data/remote-$mode/brief.md"
done
FM_HOME="$TMP" bash "$ROOT/bin/fm-brief.sh" remote-scout sample --scout --tests focused >/dev/null
if grep -q fm-test-remote.py "$TMP/data/remote-scout/brief.md"; then
  echo 'scout received ship-only remote testing instructions' >&2; exit 1
fi
promote_scout remote-promote-on
test "$(grep -c 'fm-test-remote.py' "$TMP/data/remote-promote-on/ship-instructions.md")" -eq 1
grep -q 'browser journeys, full server partitions, repeat loops' "$TMP/data/remote-promote-on/ship-instructions.md"
printf 'PASS remote testing instruction appears only in configured ship briefs and promotions\n'
# Disposable linked task copy with every kind of uncommitted change; the fake
# SSH restores the shipped snapshot and compares it with these literal bytes.
fixture_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"; }
mkdir -p "$TMP/repo/sub"
printf 'ignored.txt\n' > "$TMP/repo/.gitignore"
printf 'base staged\n' > "$TMP/repo/staged.txt"
printf 'base unstaged\n' > "$TMP/repo/unstaged.txt"
printf 'base deleted\n' > "$TMP/repo/deleted.txt"
printf '\000\001' > "$TMP/repo/bin.dat"
printf 'kept\n' > "$TMP/repo/sub/keep.txt"
fixture_git -C "$TMP/repo" add -A
fixture_git -C "$TMP/repo" commit -q -m fixture
fixture_git -C "$TMP/repo" worktree add -q --detach "$TMP/task"
printf 'staged edit\n' > "$TMP/task/staged.txt"
printf 'staged new file\n' > "$TMP/task/added.txt"
fixture_git -C "$TMP/task" add staged.txt added.txt
fixture_git -C "$TMP/task" rm -q deleted.txt
printf 'unstaged edit\n' > "$TMP/task/unstaged.txt"
printf '\000\002\377' > "$TMP/task/bin.dat"
printf 'untracked file\n' > "$TMP/task/untracked.txt"
printf 'ignored secret\n' > "$TMP/task/ignored.txt"
FM_REMOTE_TEST_HEAD=$(git -C "$TMP/task" rev-parse HEAD)
export FM_REMOTE_TEST_HEAD
# Explicit transport injection, never PATH shadowing.
cat > "$TMP/ssh" <<'PY'
#!/usr/bin/env python3
import hashlib, io, json, os, pathlib, shlex, subprocess, sys, tarfile, tempfile
args = sys.argv[1:]
mode = os.environ.get('FM_REMOTE_TEST_MODE', '')
for option in ('BatchMode=yes', 'IdentitiesOnly=yes', 'StrictHostKeyChecking=yes'):
    assert option in args, args
assert args.count('tests@example.invalid') == 1
stream = sys.stdin.buffer
header = json.loads(stream.readline())
worker = stream.read(header['worker_size'])
archive = stream.read(header['archive_size'])
assert hashlib.sha256(worker).hexdigest() == header['worker_sha256']
expected = {'.gitignore': b'ignored.txt\n', 'staged.txt': b'staged edit\n', 'unstaged.txt': b'unstaged edit\n',
            'added.txt': b'staged new file\n', 'bin.dat': b'\x00\x02\xff', 'untracked.txt': b'untracked file\n',
            'sub/keep.txt': b'kept\n'}
git_env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
with tarfile.open(fileobj=io.BytesIO(archive)) as tar, tempfile.TemporaryDirectory() as scratch:
    request = json.load(tar.extractfile('request.json'))
    assert request['head'] == os.environ['FM_REMOTE_TEST_HEAD'], request
    if not mode:
        assert request['command'] == ['printf', '%s', 'argument with spaces; $literal']
        assert request['timeout'] == 17
        assert request['cwd'] == 'sub', request
    scratch = pathlib.Path(scratch)
    (scratch / 'head.bundle').write_bytes(tar.extractfile('head.bundle').read())
    (scratch / 'changes.patch').write_bytes(tar.extractfile('changes.patch').read())
    tree = scratch / 'tree'
    subprocess.run(['git', 'clone', '-q', '--no-checkout', str(scratch / 'head.bundle'), str(tree)], env=git_env, check=True)
    subprocess.run(['git', '-C', str(tree), 'checkout', '-q', '--detach', request['head']], env=git_env, check=True)
    subprocess.run(['git', '-C', str(tree), 'apply', '--binary', str(scratch / 'changes.patch')], env=git_env, check=True)
    with tarfile.open(fileobj=io.BytesIO(tar.extractfile('untracked.tar').read())) as untracked:
        untracked.extractall(tree, filter='data')
    restored = {str(path.relative_to(tree)): path.read_bytes() for path in tree.rglob('*')
                if path.is_file() and '.git' not in path.relative_to(tree).parts}
    assert restored == expected, restored
if mode:
    # Drive the real framed worker over local pipes in place of a remote host.
    if mode not in ('cap', 'oom'):
        # An invalid execution timeout means no execution scope can launch.
        header['config']['timeout'] = 1
    env = dict(os.environ)
    if mode == 'oom':
        env['PATH'] = os.environ['FM_REMOTE_TEST_STUB'] + os.pathsep + env['PATH']
    child = subprocess.Popen(shlex.split(args[-1]), stdin=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    child.stdin.write(json.dumps(header).encode() + b'\n' + worker)
    child.stdin.flush()
    receiving = child.stderr.readline()
    assert b'receiving r' in receiving, receiving
    sys.stderr.buffer.write(receiving)
    remote = pathlib.Path(header['config']['remote_root']).resolve()
    if mode == 'orphan':
        old = remote / 'runs' / ('r' + 'f' * 32)
        old.mkdir(mode=0o700)
        (old / 'lease').touch()
        (remote / 'slot-0.owner').write_text(old.name)
    elif mode == 'invalid-owner':
        (remote / 'slot-0.owner').write_text('not-a-generated-run')
    child.stdin.write(archive)
    child.stdin.flush()
    for line in child.stderr:
        sys.stderr.buffer.write(line)
        sys.stderr.buffer.flush()
    child.wait(timeout=120)
    child.stdin.close()
    sys.exit(child.returncode)
print('remote-stdout', flush=True)
print('remote-stderr', file=sys.stderr, flush=True)
print('FM_TEST_RESULT_' + header['nonce'] + ' ' + json.dumps({'kind': 'command', 'code': 23}), file=sys.stderr, flush=True)
PY
chmod +x "$TMP/ssh"
if (cd "$TMP/task/sub" && FM_HOME="$TMP" FM_SSH_BIN="$TMP/ssh" python3 "$ROOT/bin/fm-test-remote.py" --timeout 17 -- printf '%s' 'argument with spaces; $literal') >"$TMP/out" 2>"$TMP/err"; then
  echo 'remote exit code lost' >&2; exit 1
else
  test "$?" -eq 23 || { cat "$TMP/err" >&2; exit 1; }
fi
grep -q remote-stdout "$TMP/out"
grep -q remote-stderr "$TMP/err"
printf 'PASS snapshot fidelity, strict one-connection transport, argv and exit code\n'
# These local framed-worker regressions launch only uniquely named transient
# scopes under the caller's own user manager. Other checks need no manager.
if type -P systemctl >/dev/null && systemctl --user show --property=ActiveState --value fm-test-remote-rffffffffffffffffffffffffffffffff.scope >/dev/null 2>&1; then
FORK_TO_CAP='import os, sys, time
children = []
try:
    while len(children) < 256:
        pid = os.fork()
        if pid == 0:
            time.sleep(60)
            os._exit(0)
        children.append(pid)
except BlockingIOError:
    pass
for pid in children:
    os.kill(pid, 9)
    os.waitpid(pid, 0)
sys.exit(int(sys.argv[1]))'
for status in 0 1; do
  set +e
  (cd "$TMP/task" && FM_HOME="$TMP" FM_SSH_BIN="$TMP/ssh" FM_REMOTE_TEST_MODE=cap python3 "$ROOT/bin/fm-test-remote.py" --timeout 60 -- python3 -c "$FORK_TO_CAP" "$status") >"$TMP/out" 2>"$TMP/err"
  actual=$?
  set -e
  test "$actual" -eq "$status" || { cat "$TMP/err" >&2; echo "cap event replaced command status $status with $actual" >&2; exit 1; }
  python3 - "$TMP/err" "$status" <<'PY'
import json, sys
lines = [line for line in open(sys.argv[1], 'rb').read().splitlines() if line.startswith(b'FM_TEST_RESULT_')]
assert len(lines) == 1, lines
outcome = json.loads(lines[0].split(b' ', 1)[1])
assert outcome['kind'] == 'command' and outcome['code'] == int(sys.argv[2]), outcome
assert 'pids.events:max' in outcome['cap_events'], outcome
PY
  test -z "$(ls -A "$TMP/remote/runs")"
  test ! -e "$TMP/remote/slot-0.owner"
done
printf 'PASS command status survives a PIDs-cap event and the typed result reports it\n'
# Stub manager modelling systemd 253+ scopes: under the default OOMPolicy=stop,
# one in-scope OOM kill stops the whole scope before the command can report.
mkdir -p "$TMP/stub"
REAL_SYSTEMD_RUN=$(type -P systemd-run)
cat > "$TMP/stub/systemd-run" <<EOF
#!/usr/bin/env bash
for cap in CPUQuota= MemoryMax= MemorySwapMax=0 TasksMax= RuntimeMaxSec=; do
  case " \$* " in *" -p \$cap"*) ;; *) echo "stub systemd-run: missing \$cap" >&2; exit 1 ;; esac
done
case " \$* " in
  *" -p OOMPolicy=continue "*) exec $(printf '%q' "$REAL_SYSTEMD_RUN") "\$@" ;;
esac
touch "\${!#}/started"
echo 'stub systemd-run: OOM kill in scope; OOMPolicy=stop stopped it' >&2
exit 137
EOF
chmod +x "$TMP/stub/systemd-run"
set +e
(cd "$TMP/task" && FM_HOME="$TMP" FM_SSH_BIN="$TMP/ssh" FM_REMOTE_TEST_MODE=oom FM_REMOTE_TEST_STUB="$TMP/stub" python3 "$ROOT/bin/fm-test-remote.py" --timeout 60 -- sh -c 'exit 3') >"$TMP/out" 2>"$TMP/err"
actual=$?
set -e
test "$actual" -eq 3 || { cat "$TMP/err" >&2; echo "OOM policy stopped the scope: status 3 became $actual" >&2; exit 1; }
test -z "$(ls -A "$TMP/remote/runs")"
printf 'PASS scope survives an in-scope OOM kill under OOMPolicy=continue\n'
for failure in orphan invalid-owner; do
  if (cd "$TMP/task/sub" && FM_HOME="$TMP" FM_SSH_BIN="$TMP/ssh" FM_REMOTE_TEST_MODE="$failure" python3 "$ROOT/bin/fm-test-remote.py" --timeout 17 -- printf '%s' 'argument with spaces; $literal') >"$TMP/out" 2>"$TMP/err"; then
    echo 'failure fixture unexpectedly succeeded' >&2; exit 1
  else
    test "$?" -eq 126
  fi
  if [ "$failure" = orphan ]; then
    grep -q 'reaped abandoned run rffffffffffffffffffffffffffffffff' "$TMP/err"
    test ! -d "$TMP/remote/runs/rffffffffffffffffffffffffffffffff"
    test ! -e "$TMP/remote/slot-0.owner"
  else
    grep -q 'invalid slot owner' "$TMP/err"
    test "$(<"$TMP/remote/slot-0.owner")" = not-a-generated-run
  fi
done
printf 'PASS slot acquisition reconciles orphans and refuses invalid owner records\n'
else
  printf 'SKIP framed-worker scope regressions: need a reachable systemd user manager\n'
fi
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(255)\n' > "$TMP/ssh"
if (cd "$TMP/task" && FM_HOME="$TMP" FM_SSH_BIN="$TMP/ssh" python3 "$ROOT/bin/fm-test-remote.py" -- true) >"$TMP/out" 2>"$TMP/err"; then
  echo 'transport failure unexpectedly succeeded' >&2; exit 1
else
  test "$?" -eq 125
fi
grep -q 'transport or remote setup failed' "$TMP/err"
printf 'PASS early SSH failure is transport failure, not cancellation\n'
