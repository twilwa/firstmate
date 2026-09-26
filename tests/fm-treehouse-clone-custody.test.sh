#!/usr/bin/env bash
# Token-free real Treehouse allocations driven by fm-spawn's emitted command.
# All repositories, roots, shell processes, trust and task state are temporary;
# the terminal transport is fake and no worker harness is submitted a prompt.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate default-on FM_TREEHOUSE_CLONE_CUSTODY treehouse git jq
TMP_ROOT=$(fm_test_tmproot fm-treehouse-clone-custody)
TREEHOUSE_BIN=$(type -P treehouse)
export HOME="$TMP_ROOT/user" XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_DATA_HOME="$TMP_ROOT/data"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
export TREEHOUSE_ROOT="$TMP_ROOT/legacy pool"
printf '# Treehouse under test: %s\n' "$("$TREEHOUSE_BIN" --version)"

fm_git_init_commit "$TMP_ROOT/seed"
git clone --quiet --bare "$TMP_ROOT/seed" "$TMP_ROOT/origin.git"
CLONE_A="$TMP_ROOT/primary/repo"
CLONE_B="$TMP_ROOT/secondmate with ' quote/repo"
git clone --quiet "file://$TMP_ROOT/origin.git" "$CLONE_A"
git clone --quiet "file://$TMP_ROOT/origin.git" "$CLONE_B"
COMMON_A=$(cd "$CLONE_A/.git" && pwd -P)
COMMON_B=$(cd "$CLONE_B/.git" && pwd -P)

# Preserve a legacy pool allocated by A, including unfinished work. No new
# allocation or return may touch its state even with this ambient root set.
old_lease=$(cd "$CLONE_A" && "$TREEHOUSE_BIN" --root "$TREEHOUSE_ROOT" get \
  --no-fetch --lease --lease-holder legacy-fixture --json)
OLD_WT=$(printf '%s' "$old_lease" | jq -er .path)
(cd "$CLONE_A" && "$TREEHOUSE_BIN" --root "$TREEHOUSE_ROOT" return "$OLD_WT" \
  --if-lease-id "$(printf '%s' "$old_lease" | jq -er .lease_id)" --if-lease-holder legacy-fixture)
printf 'unlanded legacy work\n' > "$OLD_WT/keep.txt"
OLD_STATE="$(dirname "$(dirname "$OLD_WT")")/treehouse-state.json"
cp "$OLD_STATE" "$TMP_ROOT/legacy-state"
git -C "$OLD_WT" reflog > "$TMP_ROOT/legacy-reflog"

FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake")
rm "$FAKEBIN/treehouse"
ln -s "$TREEHOUSE_BIN" "$FAKEBIN/treehouse"
fm_test_fake_sleep_noop "$FAKEBIN"
mv "$FAKEBIN/tmux" "$FAKEBIN/tmux-fixture"
cat > "$TMP_ROOT/probe-shell" <<'SH'
#!/usr/bin/env bash
pwd -P > "$FM_TEST_ALLOCATED_PATH"
SH
chmod +x "$TMP_ROOT/probe-shell"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  *'#{pane_current_path}'*) cat "$FM_TEST_ALLOCATED_PATH"; exit 0 ;;
esac
if [ "${1:-}" = send-keys ]; then
  for payload in "$@"; do
    case "$payload" in
      treehouse\ *)
        (cd "$FM_TEST_REQUESTING_PROJECT" && SHELL="$FM_TEST_PROBE_SHELL" bash -c "$payload")
        exit ;;
    esac
  done
fi
exec "$(dirname "$0")/tmux-fixture" "$@"
SH
chmod +x "$FAKEBIN/tmux"
head -n2 "$FAKEBIN/tmux" >/dev/null
HOME_DIR="$TMP_ROOT/home"
fm_test_spawn_home "$HOME_DIR" codex

allocate() { # <id> <requesting-project> <expected-common-dir>
  local id=$1 project=$2 expected=$3 out common
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(FM_TEST_REQUESTING_PROJECT="$project" FM_TEST_PROBE_SHELL="$TMP_ROOT/probe-shell" \
    FM_TEST_ALLOCATED_PATH="$TMP_ROOT/allocated" FM_TEST_USER_HOME="$TMP_ROOT/spawn-user" \
    fm_test_run_spawn "$HOME_DIR" ignored "$FAKEBIN" "$id" "$project" --scout) \
    || fail "real Treehouse allocation did not launch: $out"
  ALLOCATED=$(cat "$TMP_ROOT/allocated")
  common=$(git -C "$ALLOCATED" rev-parse --path-format=absolute --git-common-dir)
  common=$(cd "$common" && pwd -P)
  [ "$common" = "$expected" ] || fail "foreign clone custody: $common, expected $expected"
  case "$ALLOCATED" in
    "$TMP_ROOT/spawn-user/.treehouse-fm/"?*/.treehouse/*) ;;
    *) fail "new allocation ignored clone-scoped root: $ALLOCATED" ;;
  esac
  case "$ALLOCATED/" in
    "$HOME_DIR/"*) fail "new allocation sits inside Firstmate home: $ALLOCATED" ;;
  esac
  CLAUDE_CONFIG_DIR="$TMP_ROOT/trust" "$ROOT/bin/fm-claude-trust.sh" "$ALLOCATED" "$project" \
    || fail 'unchanged trust guard refused an own-clone allocation'
  grep -Fxq "worktree=$ALLOCATED" "$HOME_DIR/state/$id.meta" \
    || fail 'spawn did not retain real Treehouse worktree'
  pass "real Treehouse spawn $id owns its clone and passes unchanged trust"
}

allocate custody-a "$CLONE_A" "$COMMON_A"
WT_A=$ALLOCATED
allocate custody-b "$CLONE_B" "$COMMON_B"
WT_B=$ALLOCATED
[ "$WT_A" != "$WT_B" ] || fail 'independent clones reused one slot'
if CLAUDE_CONFIG_DIR="$TMP_ROOT/trust" "$ROOT/bin/fm-claude-trust.sh" "$WT_A" "$CLONE_B" \
  > "$TMP_ROOT/foreign-trust" 2>&1; then
  fail 'unchanged trust guard accepted the other clone'
fi
git -C "$CLONE_B" worktree add --quiet --detach "$TMP_ROOT/linked b" HEAD
ln -s "$TMP_ROOT/linked b" "$TMP_ROOT/linked-alias"
allocate custody-linked "$TMP_ROOT/linked-alias" "$COMMON_B"
[ "$ALLOCATED" = "$WT_B" ] || fail 'linked clone spelling failed to reuse its own pool'

# The old absolute-path return contract finds the real slot without new root
# metadata. An unrelated explicit fixture root must remain untouched.
lease=$(cd "$CLONE_B" && "$TREEHOUSE_BIN" --root "${WT_B%/.treehouse/*}" get \
  --no-fetch --lease --lease-holder return-fixture --json)
return_path=$(printf '%s' "$lease" | jq -er .path)
(cd "$CLONE_B" && "$TREEHOUSE_BIN" --root "$TREEHOUSE_ROOT" return "$return_path" \
  --if-lease-id "$(printf '%s' "$lease" | jq -er .lease_id)" --if-lease-holder return-fixture)
state="$(dirname "$(dirname "$return_path")")/treehouse-state.json"
jq -e '[.worktrees[] | select(.lease_holder == "return-fixture")] | length == 0' "$state" >/dev/null \
  || fail 'exact return retained its lease'
cmp -s "$OLD_STATE" "$TMP_ROOT/legacy-state" || fail 'new allocations changed legacy pool state'
git -C "$OLD_WT" reflog > "$TMP_ROOT/legacy-reflog-after"
cmp -s "$TMP_ROOT/legacy-reflog" "$TMP_ROOT/legacy-reflog-after" || fail 'legacy HEAD changed'
assert_grep 'unlanded legacy work' "$OLD_WT/keep.txt" 'legacy work was lost'
pass 'real allocations and exact returns preserve the existing pool and its unlanded work'

echo '# all fm-treehouse-clone-custody tests passed'
