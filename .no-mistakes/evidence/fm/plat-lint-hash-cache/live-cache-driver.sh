#!/usr/bin/env bash
# Live driver: real bin/fm-lint.sh (exported from the run's HEAD into a
# disposable git repo) + the real pinned ShellCheck 0.11.0 on PATH, with a
# disposable FM_LINT_CACHE_DIR. Prints a transcript of each scenario.
set -u
SRC=$1            # run worktree (read-only: only `git archive HEAD` is used)
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint-cache-live.XXXXXX")
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
R=$T/repo C=$T/cache
mkdir -p "$R"
git -C "$SRC" archive HEAD | tar -x -C "$R"
cd "$R" || exit 1
git init -q && git add -A && git -c user.name=lab -c user.email=lab@example.invalid commit -qm fixture

mkdir -p lab/lib
printf '#!/usr/bin/env bash\nexport bar=1\n' > lab/lib/c.sh                       # level 2
printf '#!/usr/bin/env bash\n# shellcheck source=lab/lib/c.sh\n. lab/lib/c.sh\n' > lab/lib/b.sh   # level 1
printf '#!/usr/bin/env bash\n# shellcheck source=lab/lib/b.sh\n. lab/lib/b.sh\nprintf "%%s\\n" "$bar"\n' > lab/root.sh
printf '#!/usr/bin/env bash\nprintf "%%s\\n" hello\n' > lab/plain.sh
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$never_set"\n' > lab/bad.sh

lint() {  # <label> [env...] -- [fm-lint args...]
  local label=$1; shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  echo "=== $label"
  echo "\$ fm-lint.sh $*"
  local out rc=0
  out=$(env -u GITHUB_ACTIONS -u FM_LINT_REQUIRE_BOUNDS FM_LINT_CACHE_DIR="$C" ${envs[@]+"${envs[@]}"} \
    bin/fm-lint.sh "$@" 2>&1) || rc=$?
  printf '%s\n' "$out" | grep -E 'lint cache:|SC[0-9]{4}|STALE|AUDIT|^In lab|warning:|error' | sed 's/^/  /'
  echo "  rc=$rc"
}
entries() { echo "  entries: $(find "$C/fm-lint-cache-v1" -type f 2>/dev/null | wc -l)"; }

echo "shellcheck: $(command -v shellcheck) $(shellcheck --version | sed -n 2p)"
lint "S1 first run records passes (cold cache)" -- lab/root.sh lab/plain.sh; entries
lint "S1 second run replays recorded passes" -- lab/root.sh lab/plain.sh; entries

printf '#!/usr/bin/env bash\nunset bar\n' > lab/lib/c.sh
lint "S2 sourced file two levels down changed -> root misses, real SC2154 shown" -- lab/root.sh lab/plain.sh; entries
lint "S3 failing root is never replayed (run again)" -- lab/root.sh lab/plain.sh; entries
printf '#!/usr/bin/env bash\nexport bar=1\n' > lab/lib/c.sh
lint "S2b restore level-2 file -> original recorded pass key matches again" -- lab/root.sh lab/plain.sh

lint "S4 changed linter flags (--fast drops extended analysis) -> miss" -- --fast lab/root.sh lab/plain.sh
lint "S4 --fast again -> its own entry hits" -- --fast lab/root.sh lab/plain.sh

echo '# definition touch' >> bin/fm-timeout-lib.sh
lint "S5 lint-definition file changed -> every root misses" -- lab/root.sh lab/plain.sh
git checkout -q -- bin/fm-timeout-lib.sh
lint "S5 definition restored -> hits again" -- lab/root.sh lab/plain.sh

lint "S6 hosted scope never reads local entries" GITHUB_ACTIONS=true FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_JOBS=1 -- lab/root.sh lab/plain.sh
lint "S6 local run after hosted still replays only local entries" -- lab/root.sh lab/plain.sh

lint "S7 setup: hit run with telemetry to learn the replayed keys" -- --telemetry "$T/s7.tsv" lab/root.sh lab/plain.sh
one="$C/fm-lint-cache-v1/$(awk -F'\t' '$1=="root" && $2=="lab/root.sh" {print $4}' "$T/s7.cache.tsv")"
echo "  corrupting the entry this run replays: $one"
cp "$one" "$T/saved-entry"
printf 'garbage\n' > "$one"
lint "S7 one corrupt entry -> every hit discarded, everything linted" -- lab/root.sh lab/plain.sh
cp "$T/saved-entry" "$one"
chmod 000 "$C/fm-lint-cache-v1"
lint "S7 unreadable cache directory -> everything linted, never pass" -- lab/root.sh lab/plain.sh
chmod 755 "$C/fm-lint-cache-v1"

# S8: simulate a stale entry (what a key missing a dependency would produce):
# plant a well-formed pass entry for bad.sh's current key, then show a cached
# run replays it and the uncached audit fails loudly naming the key.
lint "S8 bad.sh linted cached: finding reported, not stored" -- --telemetry "$T/t.tsv" lab/bad.sh
key=$(awk -F'\t' '$1=="root" && $2=="lab/bad.sh" {print $4}' "$T/t.cache.tsv")
echo "  bad.sh current key: $key"
perl -MDigest::SHA=sha256_hex -e '($k,$r)=@ARGV; $b="fm-lint-cache-entry-v1\nkey $k\nverdict pass\nreason ok\nroot $r\n"; print $b, "check ", sha256_hex($b), "\n"' \
  "$key" lab/bad.sh > "$C/fm-lint-cache-v1/$key"
lint "S8 planted stale pass replayed by a cached run (finding hidden)" -- lab/bad.sh lab/plain.sh
lint "S8 nightly-style uncached audit ignores the cache and names the stale key" FM_LINT_CACHE_DIR= -- --audit-cache "$C" lab/bad.sh lab/plain.sh
