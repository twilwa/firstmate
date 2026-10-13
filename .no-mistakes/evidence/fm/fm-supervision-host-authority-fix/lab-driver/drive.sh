#!/usr/bin/env bash
# Drive the real firstmate PR scripts from tree $1 against a fresh lab home and the stand-in forge.
TREE=$1; WT=/home/firstmate/.no-mistakes/worktrees/8be14fbb8fb5/01M4VKA44BK3TZKE8389W05NGK
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_SUPERVISION_ACTOR FM_PR_REVIEW_EXPECTED_HEAD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
export FM_HOME=$LAB FORGE=$LAB/forge PATH=/tmp/nmlabdrv:$PATH HOME_SAFE=1
mkdir -p $FORGE; : > $FORGE/gh.log
git init -q $LAB/wt && git -C $LAB/wt -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git -C $LAB/wt update-ref refs/remotes/origin/main HEAD
printf 'window=fm-task-x1\nworktree=%s\nproject=%s/project\nkind=ship\nmode=no-mistakes\n' $LAB/wt $LAB > $LAB/state/task-x1.meta
cp "$TREE/.tasks.toml" $LAB/.tasks.toml 2>/dev/null; printf '## In flight\n\n## Queued\n\n## Done\n' > $LAB/data/backlog.md
HIGH='{"filename":"bin/fm-teardown.sh","status":"modified","additions":5,"deletions":1}'
mkpr() { # num head checks-json
  local P=$FORGE/pr-$1; mkdir -p $P; echo $2 > $P/head; echo "[$HIGH]" > $P/files.json
  printf '[{"id":9%s,"html_url":"https://github.com/example/repo/pull/%s#issuecomment-9%s","user":{"login":"maintainer"},"body":"final disposition","updated_at":"2026-10-13T15:42:10Z"}]' $1 $1 $1 > $P/final-post.json; echo '[]' > $P/comments.json
  local green='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'
  printf '%s\n' "${3:-$green}" > $P/checks.json
}
review() { # num head attest?  - real ledger lifecycle through the live snapshotter
  local url=https://github.com/example/repo/pull/$1
  FM_REVIEW_NOW_EPOCH=1000 $TREE/bin/fm-pr-review.sh init task-x1 $url >/dev/null || echo "!! init failed"
  FM_REVIEW_NOW_EPOCH=1600 $TREE/bin/fm-pr-review.sh checkpoint $url >/dev/null || echo "!! checkpoint failed"
  [ "$3" = attest ] && { $TREE/bin/fm-pr-review.sh attest $url $2 no-mistakes claude-opus-5-5 'gate run at the configured exact model' >/dev/null || echo "!! attest failed"; }
  cp $FORGE/pr-$1/final-post.json $FORGE/pr-$1/comments.json  # worker posts the final disposition
  $TREE/bin/fm-pr-review.sh final-disposition $url $2 "$url#issuecomment-9$1" >/dev/null || echo "!! final-disposition failed"
}
run() { echo; echo "\$ $*"; ( cd "$TREE"; "$@" ) 2>&1 | sed "s#$LAB#<LAB>#g; s#$TREE#<TREE>#g" | grep -v '^  *\(number\|status\):' ; echo "exit=${PIPESTATUS[0]}"; }
merged() { [ -f $FORGE/pr-$1/merged ] && echo "FORGE: PR $1 MERGED" || echo "FORGE: PR $1 still open (no gh pr merge reached the forge)"; }
H1=1111111111111111111111111111111111111111; H2=2222222222222222222222222222222222222222; H3=3333333333333333333333333333333333333333
H4=4444444444444444444444444444444444444444; H5=5555555555555555555555555555555555555555; H6=6666666666666666666666666666666666666666
mkpr 300 $H6; mkpr 240 $H1; mkpr 218 $H2; mkpr 250 $H3 '[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]'; mkpr 260 $H4
for n in 300 240 250 260; do :; done
review 300 $H6 noattest; review 240 $H1 noattest; review 218 $H2 attest; review 250 $H3 attest; review 260 $H4 attest
echo "=== S-attended: attended, MAIN calls bin/fm-pr-merge.sh directly on PR 300 (no attestation) - unchanged attended path"
run bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/300; merged 300
echo; echo "=== captain leaves: away record entered"
run bin/fm-afk-contract.sh enter --words 'land further fixes, improvements'
echo; echo "=== S-PR240: away, branch calls bin/fm-pr-merge.sh directly on high-stakes PR 240 lacking the exact-model attestation"
run env FM_SUPERVISION_ACTOR=branch bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/240; merged 240
echo; echo "=== S-handset: away, branch hand-sets FM_PR_REVIEW_EXPECTED_HEAD=<live head> on PR 240"
run env FM_SUPERVISION_ACTOR=branch FM_PR_REVIEW_EXPECTED_HEAD=$H1 bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/240; merged 240
echo; echo "=== S-wrapper-unattested: away, branch uses bin/fm-pr-review.sh merge on PR 240"
run env FM_SUPERVISION_ACTOR=branch bin/fm-pr-review.sh merge task-x1 https://github.com/example/repo/pull/240; merged 240
echo; echo "=== S-PR218: away, branch uses bin/fm-pr-review.sh merge on fully reviewed + attested PR 218 (base requires no checks)"
run env FM_SUPERVISION_ACTOR=branch bin/fm-pr-review.sh merge task-x1 https://github.com/example/repo/pull/218; merged 218
run sh -c "jq -c '.generations[-1] | {merge_decision:(.merge_decision|{decision,verified_head}), checks}' $LAB/data/pr-review-ledger/github--example--repo--218.json"
run sh -c "grep 'merge landed' $LAB/state/.wake-queue || echo 'no merge-landed outcome'"
echo; echo "=== S-red: away, PR 250 has a red 'lint' check: wrapper, then direct --allow-red"
run env FM_SUPERVISION_ACTOR=branch bin/fm-pr-review.sh merge task-x1 https://github.com/example/repo/pull/250; merged 250
run env FM_SUPERVISION_ACTOR=branch bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/250 --allow-red lint; merged 250
echo; echo "=== S-stale: PR 250's ledger recorded merge for head 3333 (red, refused); the worker then pushes green head 7777 without a new review"
H7=7777777777777777777777777777777777777777; echo $H7 > $FORGE/pr-250/head; echo '[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}]' > $FORGE/pr-250/checks.json
run sh -c "jq -c '.generations[-1].merge_decision|{decision,verified_head}' $LAB/data/pr-review-ledger/github--example--repo--250.json"
run env FM_SUPERVISION_ACTOR=branch FM_PR_REVIEW_EXPECTED_HEAD=$H7 bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/250; merged 250
run env FM_SUPERVISION_ACTOR=branch FM_PR_REVIEW_EXPECTED_HEAD=$H3 bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/250; merged 250
echo; echo "=== S-hold: PR 260 fully reviewed but held for the captain"
run bin/fm-pr-review.sh hold https://github.com/example/repo/pull/260 $H4 "captain's word to land"
run env FM_SUPERVISION_ACTOR=branch bin/fm-pr-review.sh release-hold https://github.com/example/repo/pull/260 $H4 https://example.test/decision
run env FM_SUPERVISION_ACTOR=branch bin/fm-pr-review.sh merge task-x1 https://github.com/example/repo/pull/260; merged 260
echo; echo "=== captain returns: away record archived"
run bin/fm-afk-contract.sh archive
run env FM_SUPERVISION_ACTOR=branch bin/fm-pr-review.sh release-hold https://github.com/example/repo/pull/260 $H4 https://example.test/decision
run bin/fm-pr-review.sh release-hold https://github.com/example/repo/pull/260 $H4 https://example.test/decision
run sh -c "jq -c '.generations[-1].merge_decision' $LAB/data/pr-review-ledger/github--example--repo--260.json"
echo; echo "--- forge merge calls:"; grep '^pr merge' $FORGE/gh.log | sed "s#$LAB#<LAB>#g"
rm -rf "$LAB"; echo "(lab removed)"
