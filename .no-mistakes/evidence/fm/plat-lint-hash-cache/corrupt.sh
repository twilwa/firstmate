#!/usr/bin/env bash
set -u
SRC=$1
T=$(mktemp -d /tmp/fmlc-corrupt.XXXXXX); R=$T/repo; C=$T/cache
mkdir -p "$R/bin" "$R/tests"
cp "$SRC/bin/fm-lint.sh" "$SRC/bin/fm-lint-cache-lib.sh" "$SRC/bin/fm-timeout-lib.sh" "$R/bin/"
printf '#!/usr/bin/env bash\necho one\n' > "$R/tests/one.sh"
printf '#!/usr/bin/env bash\necho two\n' > "$R/tests/two.sh"
printf '#!/usr/bin/env bash\necho "$undefined_x"\n' > "$R/tests/bad.sh"
cd "$R" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm f
run() { local l=$1; shift; echo; echo "### $l"; echo "\$ $*"
  ( env -u GITHUB_ACTIONS -u FM_LINT_REQUIRE_BOUNDS FM_LINT_CACHE_DIR="$C" "$@" ) 2>&1 | grep -E 'lint cache:|SC[0-9]{4}' | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"; }
ROOTS=(tests/one.sh tests/two.sh tests/bad.sh)
run "cold" bin/fm-lint.sh --telemetry "$T/t.tsv" "${ROOTS[@]}"
run "warm" bin/fm-lint.sh "${ROOTS[@]}"
k=$(awk -F'\t' '$1=="root" && $2=="tests/one.sh"{print $4}' "$T/t.cache.tsv"); echo "corrupting looked-up entry for tests/one.sh: $k (flip last byte)"
perl -e 'open my $h,"+<",$ARGV[0] or die; seek $h,-2,2; print $h "0"; close $h' "$C/fm-lint-cache-v1/$k"
run "one looked-up entry corrupt" bin/fm-lint.sh "${ROOTS[@]}"
echo "--- truncated entry"; : > "$C/fm-lint-cache-v1/$k"
run "one looked-up entry truncated to 0 bytes" bin/fm-lint.sh "${ROOTS[@]}"
rm -f "$C/fm-lint-cache-v1/$k"; run "rewarm" bin/fm-lint.sh "${ROOTS[@]}"
chmod 000 "$C"; run "cache root dir chmod 000" bin/fm-lint.sh "${ROOTS[@]}"; chmod 755 "$C"
rm -rf "$C/fm-lint-cache-v1"; printf 'not a dir' > "$C/fm-lint-cache-v1"
run "entries path replaced by a regular file" bin/fm-lint.sh "${ROOTS[@]}"
cd /; rm -rf "$T"; echo; echo "fixture removed"
