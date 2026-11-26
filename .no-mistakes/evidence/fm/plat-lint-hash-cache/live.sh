#!/usr/bin/env bash
# Live driver: real bin/fm-lint.sh + real ShellCheck 0.11.0 on a disposable fixture git repo.
set -u
SRC=$1; EV=$2
T=$(mktemp -d /tmp/fmlc-live.XXXXXX)
R=$T/repo; C=$T/cache
mkdir -p "$R/bin" "$R/tests" "$R/lib" "$T/fakebin"
cp "$SRC/bin/fm-lint.sh" "$SRC/bin/fm-lint-cache-lib.sh" "$SRC/bin/fm-timeout-lib.sh" "$R/bin/"
cat > "$R/tests/root.sh" <<'S'
#!/usr/bin/env bash
# shellcheck source=lib/a.sh
. lib/a.sh
echo "$foo"
S
cat > "$R/lib/a.sh" <<'S'
# shellcheck shell=bash
# shellcheck source=lib/b.sh
. lib/b.sh
S
printf '# shellcheck shell=bash\nfoo=1\nexport foo\n' > "$R/lib/b.sh"
printf '#!/usr/bin/env bash\necho standalone\n' > "$R/tests/other.sh"
printf '#!/usr/bin/env bash\n. /lib/x.sh\necho "$bar"\n' > "$R/tests/abs.sh"
printf '# shellcheck shell=bash\nbar=1\nexport bar\n' > "$R/lib/x.sh"
cd "$R" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture
ROOTS=(tests/root.sh tests/other.sh tests/abs.sh)
commit() { git add -A && git -c user.email=t@t -c user.name=t commit -qm "$1"; }
run() {  # label, then env/args
  local label=$1; shift
  echo; echo "### $label"; echo "\$ $*"
  ( env -u GITHUB_ACTIONS -u FM_LINT_REQUIRE_BOUNDS FM_LINT_CACHE_DIR="$C" "$@" ) 2>&1 \
    | grep -E 'lint cache:|STALE|AUDIT INCOMPLETE|SC[0-9]{4}|^In tests|corrupt|unreadable|malformed' | sed "s#$T#\$T#g"
  echo "exit=${PIPESTATUS[0]}"
}
echo "fixture: tests/root.sh -> lib/a.sh -> lib/b.sh (defines foo); tests/abs.sh -> /lib/x.sh (cwd-relative, defines bar); tests/other.sh standalone"
echo "shellcheck: $(command -v shellcheck) $(shellcheck --version | sed -n 2p)"
echo; echo "===== S1 first run records passes; second run replays only recorded passes"
run "run 1 (cold cache)" bin/fm-lint.sh "${ROOTS[@]}"
ls "$C/fm-lint-cache-v1" | sed 's/^/entry: /'
run "run 2 (unchanged)" bin/fm-lint.sh "${ROOTS[@]}"

echo; echo "===== S2 change a sourced file two levels down (lib/b.sh: foo -> baz)"
printf '# shellcheck shell=bash\nbaz=1\nexport baz\n' > lib/b.sh; commit b
run "run 3 (b.sh edited)" bin/fm-lint.sh "${ROOTS[@]}"
echo "--- S4 failing root is not recorded: rerun still lints it and still fails"
run "run 4 (b.sh still broken)" bin/fm-lint.sh "${ROOTS[@]}"

echo; echo "===== S7 nightly audit: uncached run, names stale key"
before=$(ls -l --time-style=+%s.%N "$C/fm-lint-cache-v1" | md5sum)
run "audit with no stale pass recorded" bin/fm-lint.sh --audit-cache "$C" "${ROOTS[@]}"
key=$( (env -u GITHUB_ACTIONS FM_LINT_CACHE_DIR="$C" bin/fm-lint.sh --audit-cache "$C" tests/root.sh 2>&1) | sed -n 's/.*candidate key \([0-9a-f]\{64\}\).*/\1/p' | head -1)
echo "candidate key for broken tests/root.sh: $key"
echo "--- forging a stale recorded pass for that exact key (simulates a key that missed a dependency)"
perl -MDigest::SHA=sha256_hex -e '($k,$r,$f)=@ARGV; $b="fm-lint-cache-entry-v1\nkey $k\nverdict pass\nreason ok\nroot $r\n"; open my $h,">",$f or die; print $h $b."check ".sha256_hex($b)."\n"' "$key" tests/root.sh "$C/fm-lint-cache-v1/$key"
run "cached run now replays the forged pass (the hazard the nightly backstops)" bin/fm-lint.sh --telemetry "$T/cached.tsv" "${ROOTS[@]}"
echo "sidecar rows:"; grep -E '^(root|meta)' "$T/cached.cache.tsv" | sed "s#$T#\$T#g" | sed 's/^/  /'
before=$(find "$C" -type f -printf '%P %s %T@\n' | sort | md5sum)
run "nightly audit against restored cache" bin/fm-lint.sh --audit-cache "$C" "${ROOTS[@]}"
after=$(find "$C" -type f -printf '%P %s %T@\n' | sort | md5sum)
[ "$before" = "$after" ] && echo "audit left the cache byte/mtime-identical: yes" || echo "audit left the cache byte/mtime-identical: NO"
run "nightly audit via same-commit sidecar only (no cache)" bin/fm-lint.sh --audit-record "$T/cached.cache.tsv" "${ROOTS[@]}"
rm -f "$C/fm-lint-cache-v1/$key"
printf '# shellcheck shell=bash\nfoo=1\nexport foo\n' > lib/b.sh; commit fixb

echo; echo "===== S3 changed linter flag / definition / ShellCheck build"
run "run (b.sh restored; warm)" bin/fm-lint.sh "${ROOTS[@]}"
run "--fast (different ShellCheck flags)" bin/fm-lint.sh --fast "${ROOTS[@]}"
echo '# definition edit' >> bin/fm-lint.sh; commit def
run "lint-definition file bin/fm-lint.sh edited" bin/fm-lint.sh "${ROOTS[@]}"
run "warm again" bin/fm-lint.sh "${ROOTS[@]}"
cp "$(command -v shellcheck)" "$T/fakebin/shellcheck"; printf '\0' >> "$T/fakebin/shellcheck"
echo "(fakebin/shellcheck = real 0.11.0 binary with one appended byte: same --version, different build hash)"
run "different ShellCheck build on PATH" env PATH="$T/fakebin:$PATH" bin/fm-lint.sh "${ROOTS[@]}"

echo; echo "===== S5 local vs hosted scope do not share entries"
run "local warm" bin/fm-lint.sh "${ROOTS[@]}"
run "hosted scope (GITHUB_ACTIONS=true FM_LINT_REQUIRE_BOUNDS=1)" env GITHUB_ACTIONS=true FM_LINT_REQUIRE_BOUNDS=1 bin/fm-lint.sh "${ROOTS[@]}"
run "hosted again" env GITHUB_ACTIONS=true FM_LINT_REQUIRE_BOUNDS=1 bin/fm-lint.sh "${ROOTS[@]}"
run "local again" bin/fm-lint.sh "${ROOTS[@]}"

echo; echo "===== S6 corrupt / unreadable cache lints everything and never passes a finding"
printf 'echo "$undefined_var_here"\n' >> tests/other.sh; commit bad-other
run "warm except other.sh now has a finding" bin/fm-lint.sh "${ROOTS[@]}"
f=$(ls "$C/fm-lint-cache-v1" | head -1); printf 'X' >> "$C/fm-lint-cache-v1/$f"
run "one entry corrupted (appended byte)" bin/fm-lint.sh "${ROOTS[@]}"
run "warm again" bin/fm-lint.sh "${ROOTS[@]}"
chmod 000 "$C/fm-lint-cache-v1"
run "cache entries dir chmod 000" bin/fm-lint.sh "${ROOTS[@]}"
chmod 755 "$C/fm-lint-cache-v1"
git checkout -q HEAD~1 -- tests/other.sh; commit fix-other

echo; echo "===== S8 absolute source path resolved cwd-relative (/lib/x.sh -> ./lib/x.sh)"
run "warm" bin/fm-lint.sh "${ROOTS[@]}"
printf '# shellcheck shell=bash\nqux=1\nexport qux\n' > lib/x.sh; commit x
run "lib/x.sh edited (bar removed)" bin/fm-lint.sh "${ROOTS[@]}"
echo; echo "direct shellcheck oracle on tests/abs.sh:"; shellcheck -x tests/abs.sh 2>&1 | grep -E 'SC[0-9]{4}'
chmod -R u+rwX "$T"; rm -rf "$T"; echo; echo "fixture removed"
