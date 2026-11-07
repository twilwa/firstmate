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
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
(p / 'config/remote-test.json').write_text(json.dumps(dict(host='example.invalid', user='tests', identity_file=str(p/'key'), known_hosts_file=str(p/'known_hosts'), remote_root=str(p/'remote'))))
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
printf 'PASS remote testing instruction appears only in configured ship briefs\n'
if ! test -f "$ROOT/.git"; then
  printf 'SKIP snapshot transport regression: requires an isolated linked task worktree\n'
  exit 0
fi
SENTINEL=".fm-remote-test-fixture-$$"
printf 'snapshot-fixture\n' > "$ROOT/$SENTINEL"
trap 'rm -f "$ROOT/$SENTINEL"; rm -rf "$TMP"' EXIT
export FM_REMOTE_TEST_SENTINEL="$SENTINEL" FM_REMOTE_TEST_ROOT="$ROOT"
# Explicit transport injection, never PATH shadowing. Inspect the public request
# snapshot instead of executing a remote workload in the portable regression.
cat > "$TMP/ssh" <<'PY'
#!/usr/bin/env python3
import hashlib, io, json, os, pathlib, shlex, subprocess, sys, tarfile
args = sys.argv[1:]
for option in ('BatchMode=yes', 'IdentitiesOnly=yes', 'StrictHostKeyChecking=yes'):
    assert option in args, args
assert args.count('tests@example.invalid') == 1
stream = sys.stdin.buffer
header = json.loads(stream.readline())
worker = stream.read(header['worker_size'])
archive = stream.read(header['archive_size'])
with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
    request = json.load(tar.extractfile('request.json'))
    assert request['command'] == ['printf', '%s', 'argument with spaces; $literal']
    assert request['timeout'] == 17
    assert len(tar.extractfile('head.bundle').read()) > 100
    patch = tar.extractfile('changes.patch').read()
    assert patch == subprocess.check_output(['git', '-C', os.environ['FM_REMOTE_TEST_ROOT'], 'diff', '--binary', 'HEAD', '--'])
    assert request['head'] == subprocess.check_output(['git', '-C', os.environ['FM_REMOTE_TEST_ROOT'], 'rev-parse', 'HEAD']).decode().strip()
    with tarfile.open(fileobj=io.BytesIO(tar.extractfile('untracked.tar').read())) as untracked:
        assert untracked.extractfile(os.environ['FM_REMOTE_TEST_SENTINEL']).read() == b'snapshot-fixture\n'
assert hashlib.sha256(worker).hexdigest() == header['worker_sha256']
if os.environ.get('FM_REMOTE_TEST_FAILURE'):
    # Drive the real framed worker over local pipes. Make the request timeout
    # invalid so even the old implementation cannot launch an execution scope.
    header['config']['timeout'] = 1
    child = subprocess.Popen(shlex.split(args[-1]), stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    child.stdin.write(json.dumps(header).encode() + b'\n' + worker)
    child.stdin.flush()
    receiving = child.stderr.readline()
    assert b'receiving r' in receiving, receiving
    sys.stderr.buffer.write(receiving)
    remote = pathlib.Path(header['config']['remote_root'])
    if os.environ['FM_REMOTE_TEST_FAILURE'] == 'orphan':
        old = remote / 'runs' / ('r' + 'f' * 32)
        old.mkdir(mode=0o700)
        (old / 'lease').touch()
        (remote / 'slot-0.owner').write_text(old.name)
    else:
        (remote / 'slot-0.owner').write_text('not-a-generated-run')
    child.stdin.write(archive)
    child.stdin.flush()
    child.wait(timeout=20)
    sys.stderr.buffer.write(child.stderr.read())
    child.stdin.close()
    sys.exit(child.returncode)
print('remote-stdout', flush=True)
print('remote-stderr', file=sys.stderr, flush=True)
print('FM_TEST_RESULT_' + header['nonce'] + ' ' + json.dumps({'kind': 'command', 'code': 23}), file=sys.stderr, flush=True)
PY
chmod +x "$TMP/ssh"
if FM_HOME="$TMP" FM_SSH_BIN="$TMP/ssh" python3 "$ROOT/bin/fm-test-remote.py" --timeout 17 -- printf '%s' 'argument with spaces; $literal' >"$TMP/out" 2>"$TMP/err"; then
  echo 'remote exit code lost' >&2; exit 1
else
  test "$?" -eq 23
fi
grep -q remote-stdout "$TMP/out"
grep -q remote-stderr "$TMP/err"
printf 'PASS snapshot, strict one-connection transport, argv and exit code\n'
# This local framed-worker regression only queries nonexistent units. Other
# portable CLI/transport checks do not require a Linux user manager.
if type -P systemctl >/dev/null && systemctl --user show --property=ActiveState --value fm-test-remote-rffffffffffffffffffffffffffffffff.scope >/dev/null 2>&1; then
for failure in orphan invalid-owner; do
  if FM_HOME="$TMP" FM_SSH_BIN="$TMP/ssh" FM_REMOTE_TEST_FAILURE="$failure" python3 "$ROOT/bin/fm-test-remote.py" --timeout 17 -- printf '%s' 'argument with spaces; $literal' >"$TMP/out" 2>"$TMP/err"; then
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
  printf 'SKIP framed-worker orphan regression: needs a reachable systemd user manager\n'
fi
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(255)\n' > "$TMP/ssh"
if FM_HOME="$TMP" FM_SSH_BIN="$TMP/ssh" python3 "$ROOT/bin/fm-test-remote.py" -- true >"$TMP/out" 2>"$TMP/err"; then
  echo 'transport failure unexpectedly succeeded' >&2; exit 1
else
  test "$?" -eq 125
fi
grep -q 'transport or remote setup failed' "$TMP/err"
printf 'PASS early SSH failure is transport failure, not cancellation\n'
