#!/usr/bin/env bash
# Five-invocation credentialed Codex probe for adversarial Stop-hook continuity.
# Fault creation is explicitly driver-owned; every enclosing Stop callback is
# delivered by the installed Codex hook engine from an isolated project/home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex jq timeout sha256sum

[ "${FM_CODEX_ADVERSARIAL_LIVE_E2E:-0}" = 1 ] \
  || fail "set FM_CODEX_ADVERSARIAL_LIVE_E2E=1 for the bounded adversarial probe"

MAX_INVOCATIONS=5
INVOCATIONS=${FM_CODEX_LIVE_INVOCATIONS_USED:-0}
case "$INVOCATIONS" in ''|*[!0-9]*) fail "used native invocation count must be numeric" ;; esac
[ "$INVOCATIONS" -le "$MAX_INVOCATIONS" ] || fail "used native invocation count exceeds ceiling"
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_EPOCH=$(date +%s)
DEADLINE_EPOCH=${FM_CODEX_LIVE_DEADLINE_EPOCH:-$((START_EPOCH + 5400))}
case "$DEADLINE_EPOCH" in ''|*[!0-9]*) fail "native validation deadline must be an epoch" ;; esac
[ "$DEADLINE_EPOCH" -gt "$START_EPOCH" ] || fail "native validation deadline already elapsed"
[ "$DEADLINE_EPOCH" -le $((START_EPOCH + 5400)) ] \
  || fail "native validation deadline exceeds the 90-minute ceiling"
DEADLINE_AT=$(date -u -d "@$DEADLINE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "$DEADLINE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
EVIDENCE=${FM_CODEX_LIVE_EVIDENCE_DIR:-$ROOT/.no-mistakes/codex-continuity-live-$START_EPOCH}
LAB=$(mktemp -d "$ROOT/.codex-adversarial-live.XXXXXX") \
  || fail "could not create an isolated Codex adversarial lab"
HELPERS="$LAB/helper-pids"
CODEX_VERSION=$(codex --version)

mkdir -p "$EVIDENCE"
if [ "$INVOCATIONS" -eq 0 ]; then
  printf 'started_at=%s\ndeadline_at=%s\nmax_invocations=%s\ncodex_version=%s\nlab=%s\n' \
    "$STARTED_AT" "$DEADLINE_AT" "$MAX_INVOCATIONS" "$CODEX_VERSION" "$LAB" \
    > "$EVIDENCE/provenance.txt"
else
  printf 'resumed_at=%s\nresumed_after_invocations=%s\ncodex_version=%s\nlab=%s\n' \
    "$STARTED_AT" "$INVOCATIONS" "$CODEX_VERSION" "$LAB" \
    >> "$EVIDENCE/provenance.txt"
fi

cleanup() {
  local pid
  if [ -f "$HELPERS" ]; then
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done < "$HELPERS"
  fi
  printf 'finished_at=%s\ninvocations=%s\ncleanup=helpers-reaped-lab-removed\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$INVOCATIONS" >> "$EVIDENCE/provenance.txt"
  rm -rf "$LAB"
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

assert_within_lab() {
  case "$1" in "$LAB"/*) ;; *) fail "path escaped the disposable lab: $1" ;; esac
}

snapshot_home() { # <evidence-directory> <label> <home>
  local destination=$1 label=$2 home=$3 path
  destination="$destination/$label"
  mkdir -p "$destination"
  # Dereference lab-owned lock links so the evidence survives lab cleanup.
  [ ! -d "$home/state/hook-log" ] || cp -RL "$home/state/hook-log" "$destination/"
  for path in .lock .codex-park-owner .codex-park-failures .watch.lock .watcher-down arm-count; do
    [ ! -e "$home/state/$path" ] || cp -RL "$home/state/$path" "$destination/"
  done
}

new_project() { # <name>
  local project="$LAB/$1/project"
  assert_within_lab "$project"
  mkdir -p "${project%/*}"
  git clone -q "$ROOT" "$project" || fail "could not clone the isolated $1 project"
  cp -R "$ROOT/bin/." "$project/bin/"
  cp "$ROOT/.codex/hooks.json" "$project/.codex/hooks.json"
  printf '%s\n' "$project"
}

new_home() { # <path>
  local home=$1
  assert_within_lab "$home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/bin"
  cp -R "$ROOT/bin/." "$home/bin/"
}

set_stop_hooks() { # <project> <command>...
  local project=$1 command hooks='[]'
  shift
  for command in "$@"; do
    hooks=$(jq -cn --argjson hooks "$hooks" --arg command "$command" \
      '$hooks + [{type:"command", command:$command, timeout:300}]') \
      || fail "could not compose isolated Stop hooks"
  done
  jq --argjson hooks "$hooks" '.hooks.Stop[0].hooks = $hooks' \
    "$project/.codex/hooks.json" > "$project/.codex/hooks.json.tmp" \
    || fail "could not install isolated Stop hooks"
  mv "$project/.codex/hooks.json.tmp" "$project/.codex/hooks.json"
}

run_codex() { # <label> <project> <home> <prompt>
  local label=$1 project=$2 home=$3 prompt=$4 dir transcript status=0 now
  now=$(date +%s)
  [ "$now" -lt "$DEADLINE_EPOCH" ] || fail "90-minute native validation deadline reached"
  [ "$INVOCATIONS" -lt "$MAX_INVOCATIONS" ] || fail "five-invocation ceiling reached"
  INVOCATIONS=$((INVOCATIONS + 1))
  dir="$EVIDENCE/$(printf '%02d' "$INVOCATIONS")-$label"
  transcript="$dir/codex.jsonl"
  mkdir -p "$dir"
  sha256sum "$project/.codex/hooks.json" > "$dir/hooks.sha256"
  cp "$project/.codex/hooks.json" "$dir/hooks.json"
  printf '%s\n' \
    "invocation=$INVOCATIONS/$MAX_INVOCATIONS" \
    "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "project=$project" \
    "fm_home=$home" \
    'environment=OPENAI_API_KEY and AZURE_OPENAI_API_KEY unset; installed subscription auth only' \
    'command=timeout 300 codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -c model_reasoning_effort="low" --json <prompt>' \
    > "$dir/command.txt"
  printf '%s\n' "$prompt" > "$dir/prompt.txt"
  printf 'native invocation %s/%s: %s\n' "$INVOCATIONS" "$MAX_INVOCATIONS" "$label"
  (
    cd "$project" || exit 1
    env -u OPENAI_API_KEY -u AZURE_OPENAI_API_KEY \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$project" timeout 300 codex exec \
      --dangerously-bypass-hook-trust \
      --dangerously-bypass-approvals-and-sandbox \
      --skip-git-repo-check \
      -c 'model_reasoning_effort="low"' \
      --json "$prompt"
  ) > "$transcript" 2>&1 || status=$?
  printf 'exit=%s\nfinished_at=%s\n' "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> "$dir/command.txt"
  [ "$status" -eq 0 ] \
    || fail "$label native Codex invocation failed with $status: $(tail -20 "$transcript")"
}

write_hook_wrapper() { # <project>
  local project=$1
  cat > "$project/bin/fm-codex-live-stop-wrapper.sh" <<'SH'
#!/usr/bin/env bash
set -u
mode=$1
home=$2
main_home=$3
payload=$(cat 2>/dev/null || true)
mkdir -p "$home/state/hook-log"
stamp="$(date +%s).${BASHPID:-$$}"
printf '%s\n' "$payload" > "$home/state/hook-log/$stamp.payload.json"
if [ -e "$home/state/hook-complete" ]; then
  exit 0
fi
i=0
while [ ! -s "$main_home/state/.lock" ] && [ "$i" -lt 100 ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ "$home" != "$main_home" ]; then
  cp "$main_home/state/.lock" "$home/state/.lock" || exit 1
fi
status=0
case "$mode" in
  owner-lock)
    FM_HOME="$home" FM_ROOT_OVERRIDE="$(pwd -P)" FM_CODEX_PARK_LOCK_ATTEMPTS=1 \
      "$home/bin/fm-codex-stop-park.sh" <<<"$payload" \
      > "$home/state/hook-log/$stamp.out" 2> "$home/state/hook-log/$stamp.err" || status=$?
    : > "$home/state/hook-complete"
    ;;
  publication)
    chmod 0555 "$home/state"
    FM_HOME="$home" FM_ROOT_OVERRIDE="$(pwd -P)" \
      "$home/bin/fm-codex-stop-park.sh" <<<"$payload" \
      > "$home/state/hook-log/$stamp.out" 2> "$home/state/hook-log/$stamp.err" || status=$?
    chmod 0755 "$home/state"
    : > "$home/state/hook-complete"
    ;;
  delivery|arm-failure)
    FM_HOME="$home" FM_ROOT_OVERRIDE="$(pwd -P)" FM_CODEX_PARK_LOCK_ATTEMPTS=1 \
      "$home/bin/fm-codex-stop-park.sh" <<<"$payload" \
      > "$home/state/hook-log/$stamp.out" 2> "$home/state/hook-log/$stamp.err" || status=$?
    if grep -q 'FAILURE BUDGET EXHAUSTED' "$home/state/hook-log/$stamp.out" 2>/dev/null \
      || [ "$mode" = delivery ]; then
      : > "$home/state/hook-complete"
    fi
    ;;
  replacement)
    FM_HOME="$home" FM_ROOT_OVERRIDE="$(pwd -P)" \
      "$home/bin/fm-codex-stop-park.sh" <<<"$payload" \
      > "$home/state/hook-log/$stamp.out" 2> "$home/state/hook-log/$stamp.err" || status=$?
    ;;
  concurrency|concurrency-delivery)
    FM_HOME="$home" FM_ROOT_OVERRIDE="$(pwd -P)" \
      FM_CODEX_PARK_POLL=1 FM_CODEX_PARK_RENEW_SECONDS=15 \
      "$PWD/bin/fm-codex-stop-park.sh" <<<"$payload" \
      > "$home/state/hook-log/$stamp.out" 2> "$home/state/hook-log/$stamp.err" || status=$?
    ;;
  init-timeout|marker-failure)
    if [ "$mode" = marker-failure ]; then
      PATH="$home/fakebin:$PATH" REAL_MKTEMP=/usr/bin/mktemp \
        FM_HOME="$home" FM_ROOT_OVERRIDE="$(pwd -P)" \
        FM_CODEX_PARK_POLL=1 FM_CODEX_PARK_RENEW_SECONDS=30 \
        "$home/bin/fm-codex-stop-park.sh" <<<"$payload" \
        > "$home/state/hook-log/$stamp.out" 2> "$home/state/hook-log/$stamp.err" || status=$?
    else
      FM_HOME="$home" FM_ROOT_OVERRIDE="$(pwd -P)" FM_POLL=30 \
        FM_CODEX_PARK_POLL=1 FM_CODEX_PARK_RENEW_SECONDS=2 \
        "$home/bin/fm-codex-stop-park.sh" <<<"$payload" \
        > "$home/state/hook-log/$stamp.out" 2> "$home/state/hook-log/$stamp.err" || status=$?
    fi
    : > "$home/state/hook-complete"
    ;;
  *) exit 2 ;;
esac
[ ! -s "$home/state/hook-log/$stamp.out" ] || cat "$home/state/hook-log/$stamp.out"
[ ! -s "$home/state/hook-log/$stamp.err" ] || cat "$home/state/hook-log/$stamp.err" >&2
exit "$status"
SH
  chmod +x "$project/bin/fm-codex-live-stop-wrapper.sh"
}

assert_native_stops() { # <home> [minimum]
  local home=$1 minimum=${2:-1} count
  count=$(jq -e 'select(.hook_event_name == "Stop")' "$home/state/hook-log/"*.payload.json \
    2>/dev/null | grep -c 'hook_event_name' || true)
  [ "$count" -ge "$minimum" ] \
    || fail "expected at least $minimum native Stop payloads for $home, saw $count"
}

run_infrastructure_failures() {
  local project main owner publication delivery arm_failure holder command base
  project=$(new_project infrastructure)
  main="$LAB/infrastructure/main"
  owner="$LAB/infrastructure/owner"
  publication="$LAB/infrastructure/publication"
  delivery="$LAB/infrastructure/delivery"
  arm_failure="$LAB/infrastructure/arm-failure"
  for base in "$main" "$owner" "$publication" "$delivery" "$arm_failure"; do
    new_home "$base"
  done
  : > "$owner/state/live.meta"
  : > "$publication/state/live.meta"
  : > "$delivery/state/live.meta"
  : > "$arm_failure/state/live.meta"
  write_hook_wrapper "$project"

  sleep 300 & holder=$!
  printf '%s\n' "$holder" >> "$HELPERS"
  mkdir "$owner/state/.codex-park-owner.lock"
  printf '%s\n' "$holder" > "$owner/state/.codex-park-owner.lock/pid"

  cat > "$delivery/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
setsid sleep 300 >/dev/null 2>&1 &
holder=$!
printf '%s\n' "$holder" > "$FM_HOME/state/delivery-holder"
mkdir "$FM_HOME/state/.codex-park-owner.lock"
printf '%s\n' "$holder" > "$FM_HOME/state/.codex-park-owner.lock/pid"
printf 'signal: driver-injected-delivery.status\n'
SH
  cat > "$arm_failure/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: FAILED - driver-injected arm failure\n'
exit 1
SH
  chmod +x "$delivery/bin/fm-watch-arm.sh" "$arm_failure/bin/fm-watch-arm.sh"

  # shellcheck disable=SC2016 # Hook-shell expansion is intentionally deferred.
  command='"$(pwd -P)"/bin/fm-codex-live-stop-wrapper.sh'
  set_stop_hooks "$project" \
    "$command owner-lock $owner $main" \
    "$command publication $publication $main" \
    "$command delivery $delivery $main" \
    "$command arm-failure $arm_failure $main"
  run_codex infrastructure "$project" "$main" \
    'Reply with exactly INFRA_READY. Whenever a Stop hook continues the turn, reply with exactly INFRA_RETRY and do not run tools.'

  snapshot_home "$EVIDENCE/01-infrastructure" owner "$owner"
  snapshot_home "$EVIDENCE/01-infrastructure" publication "$publication"
  snapshot_home "$EVIDENCE/01-infrastructure" delivery "$delivery"
  snapshot_home "$EVIDENCE/01-infrastructure" arm-failure "$arm_failure"
  assert_native_stops "$owner"
  assert_native_stops "$publication"
  assert_native_stops "$delivery"
  assert_native_stops "$arm_failure" 4
  grep -R -q 'owner lock could not be acquired' "$owner/state/hook-log" \
    || fail "native owner-lock callback did not expose its failure"
  grep -R -q 'state directory is not writable' "$publication/state/hook-log" \
    || fail "native publication callback did not expose its failure"
  grep -R -q 'actionable-wake delivery lock' "$delivery/state/hook-log" \
    || fail "native delivery callback did not expose its failure"
  grep -R -q 'FAILURE BUDGET EXHAUSTED' "$arm_failure/state/hook-log" \
    || fail "native arm-failure callbacks did not stop at the bounded budget"
  if [ -s "$delivery/state/delivery-holder" ]; then
    holder=$(cat "$delivery/state/delivery-holder")
    printf '%s\n' "$holder" >> "$HELPERS"
  fi
  printf 'ok - native concurrent Stop callbacks exposed driver-induced owner, publication, delivery, and bounded arm failures\n'
}

write_replacement_arm() { # <home>
  local home=$1
  cat > "$home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
mode=$(cat "$FM_HOME/state/driver-mode")
count=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$FM_HOME/state/arm-count"
case "$mode:$count" in
  reset:2) printf 'signal: driver-injected-reset.status\n' ;;
  reset:4)
    rm -f "$FM_HOME/state/live.meta"
    printf 'watcher: attached pid=%s (driver terminal close)\n' "$$"
    ;;
  *)
    printf 'watcher: FAILED - driver-injected staged failure\n'
    exit 1
    ;;
esac
SH
  chmod +x "$home/bin/fm-watch-arm.sh"
}

run_replacement_sessions() {
  local project home command first_owner second_owner
  project=$(new_project replacement)
  home="$LAB/replacement/home"
  new_home "$home"
  : > "$home/state/live.meta"
  printf 'exhaust\n' > "$home/state/driver-mode"
  write_hook_wrapper "$project"
  write_replacement_arm "$home"
  # shellcheck disable=SC2016 # Hook-shell expansion is intentionally deferred.
  command='"$(pwd -P)"/bin/fm-codex-live-stop-wrapper.sh'
  set_stop_hooks "$project" "$command replacement $home $home"

  run_codex replacement-one "$project" "$home" \
    'Reply with exactly REPLACEMENT_ONE. Whenever a Stop hook continues the turn, reply with exactly REPLACEMENT_ONE_RETRY and do not run tools.'
  first_owner=$(cat "$home/state/.lock")
  snapshot_home "$EVIDENCE/02-replacement-one" replacement "$home"
  grep -R -q 'FAILURE BUDGET EXHAUSTED' "$home/state/hook-log" \
    || fail "first native replacement session did not exhaust its own failure budget"

  rm -rf "$home/state/hook-log"
  rm -f "$home/state/.codex-park-failures" "$home/state/.codex-park-owner" "$home/state/arm-count"
  : > "$home/state/live.meta"
  printf 'reset\n' > "$home/state/driver-mode"
  run_codex replacement-two "$project" "$home" \
    'Reply with exactly REPLACEMENT_TWO. Whenever a Stop hook continues the turn, reply with exactly REPLACEMENT_TWO_RETRY and do not run tools.'
  second_owner=$(cat "$home/state/.lock")
  snapshot_home "$EVIDENCE/03-replacement-two" replacement "$home"
  [ "$first_owner" != "$second_owner" ] \
    || fail "replacement native Codex session reused the prior dead session owner"
  assert_native_stops "$home" 4
  [ "$(grep -R -c 'repair attempt 1 of 3' "$home/state/hook-log"/* 2>/dev/null \
    | awk -F: '{sum += $2} END {print sum + 0}')" -eq 2 ] \
    || fail "delivered wake did not reset the replacement session failure episode"
  ! grep -R -q 'repair attempt 2 of 3' "$home/state/hook-log" \
    || fail "replacement wake retained the prior failure count"
  grep -R -q 'driver-injected-reset.status' "$home/state/hook-log" \
    || fail "replacement session did not deliver the staged reset wake"
  printf 'ok - two native Codex sessions proved replacement ownership and a driver-staged wake reset to attempt one\n'
}

run_concurrent_renewal() {
  local project home command controller owner_pid i
  project=$(new_project concurrency)
  home="$LAB/concurrency/home"
  new_home "$home"
  : > "$home/state/live.meta"
  write_hook_wrapper "$project"
  # shellcheck disable=SC2016 # Hook-shell expansion is intentionally deferred.
  command='"$(pwd -P)"/bin/fm-codex-live-stop-wrapper.sh'
  set_stop_hooks "$project" \
    "$command concurrency $home $home" \
    "$command concurrency $home $home"
  (
    i=0
    while [ "$i" -lt 240 ]; do
      if [ -s "$home/state/.codex-park-owner" ] \
        && grep -q '^seq=[2-9][0-9]* ' "$home/state/.codex-park-owner" 2>/dev/null \
        && [ -e "$home/state/.last-watcher-beat" ]; then
        printf 'done: native concurrent Stop event\n' > "$home/state/live.status"
        exit 0
      fi
      sleep 0.25
      i=$((i + 1))
    done
    exit 1
  ) &
  controller=$!
  printf '%s\n' "$controller" >> "$HELPERS"

  # shellcheck disable=SC2016 # Prompt quotes literal model-side environment syntax.
  run_codex concurrency "$project" "$home" \
    'Reply with exactly CONCURRENCY_READY. If a watcher wake continues this turn, run bin/fm-wake-drain.sh, handle live.status, run its exact WAKE_ACK_REQUIRED command, then reply exactly WAKE_HANDLED. If a WATCHER PARK RENEWAL continues the turn, run rm -f "$FM_HOME/state/live.meta" and reply exactly RENEW_HANDLED.'
  snapshot_home "$EVIDENCE/04-concurrency" concurrency "$home"
  wait "$controller" || fail "concurrent native Stop handlers never owned a real watcher before the event"
  awk -v pid="$controller" '$0 != pid' "$HELPERS" > "$HELPERS.tmp"
  mv "$HELPERS.tmp" "$HELPERS"
  grep -q 'WAKE_HANDLED' "$EVIDENCE/04-concurrency/codex.jsonl" \
    || fail "concurrent native Stop wake did not resume the parent turn"
  grep -q 'RENEW_HANDLED' "$EVIDENCE/04-concurrency/codex.jsonl" \
    || fail "quiet native Stop renewal did not resume the parent turn"
  [ "$(grep -R -c 'firstmate watcher wake' "$home/state/hook-log"/* 2>/dev/null \
    | awk -F: '{sum += $2} END {print sum + 0}')" -eq 1 ] \
    || fail "concurrent matching Stop handlers duplicated or lost the watcher delivery"
  [ "$(grep -R -c 'WATCHER PARK RENEWAL' "$home/state/hook-log"/* 2>/dev/null \
    | awk -F: '{sum += $2} END {print sum + 0}')" -eq 1 ] \
    || fail "concurrent matching Stop handlers duplicated or lost the quiet renewal"
  owner_pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$owner_pid" ] || ! kill -0 "$owner_pid" 2>/dev/null \
    || fail "concurrent Stop supersession left a live watcher after no-work stand-down"
  printf 'ok - one native Stop event launched concurrent matching handlers; owner sequencing delivered once and a later quiet park renewed once\n'
}

run_cleanup_failures() {
  local project main init marker publication command holder
  project=$(new_project cleanup)
  main="$LAB/cleanup/main"
  init="$LAB/cleanup/init-timeout"
  marker="$LAB/cleanup/marker-failure"
  publication="$LAB/cleanup/publication"
  new_home "$main"
  new_home "$init"
  new_home "$marker"
  new_home "$publication"
  : > "$init/state/live.meta"
  : > "$marker/state/live.meta"
  : > "$publication/state/live.meta"
  printf 'announced:downtime:driver-fixture\n' > "$marker/state/.watcher-down"
  mkdir -p "$marker/fakebin"
  cat > "$marker/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  *.watcher-down.tmp.*) exit 1 ;;
esac
exec "$REAL_MKTEMP" "$@"
SH
  chmod +x "$marker/fakebin/mktemp"
  write_hook_wrapper "$project"

  sleep 300 & holder=$!
  printf '%s\n' "$holder" >> "$HELPERS"
  mkdir "$init/state/.watcher-down.lock"
  printf '%s\n' "$holder" > "$init/state/.watcher-down.lock/pid"

  # shellcheck disable=SC2016 # Hook-shell expansion is intentionally deferred.
  command='"$(pwd -P)"/bin/fm-codex-live-stop-wrapper.sh'
  set_stop_hooks "$project" \
    "$command init-timeout $init $main" \
    "$command marker-failure $marker $main" \
    "$command publication $publication $main"
  run_codex cleanup "$project" "$main" \
    'Reply with exactly CLEANUP_READY. Whenever a Stop hook continues the turn, reply with exactly CLEANUP_RETRY and do not run tools.'

  snapshot_home "$EVIDENCE/05-cleanup" init-timeout "$init"
  snapshot_home "$EVIDENCE/05-cleanup" marker-failure "$marker"
  snapshot_home "$EVIDENCE/05-cleanup" publication "$publication"
  assert_native_stops "$init"
  assert_native_stops "$marker"
  assert_native_stops "$publication"
  [ ! -s "$init/state/.watch.lock/pid" ] \
    || fail "timeout during post-claim watcher initialization retained its watcher lock"
  [ -s "$marker/state/.watch.lock/pid" ] \
    || fail "selective recovery-marker failure discarded diagnostic watcher-lock evidence"
  grep -R -q 'WATCHER PARK RENEWAL' "$init/state/hook-log" \
    || fail "native callback did not report its bounded post-claim timeout renewal"
  grep -R -q 'WATCHER PARK FAILED' "$marker/state/hook-log" \
    || fail "native callback did not surface the driver-induced marker failure"
  grep -R -q 'state directory is not writable' "$publication/state/hook-log" \
    || fail "native callback did not bound the unwritable-state publication failure"
  printf 'ok - native Stop callbacks enclosed post-claim cleanup, marker evidence retention, and bounded unwritable-state refusal\n'
}

run_final_combined() {
  local project main concurrency init marker publication command controller owner_pid holder prompt
  project=$(new_project final-combined)
  main="$LAB/final-combined/main"
  concurrency="$LAB/final-combined/concurrency"
  init="$LAB/final-combined/init-timeout"
  marker="$LAB/final-combined/marker-failure"
  publication="$LAB/final-combined/publication"
  new_home "$main"
  new_home "$concurrency"
  new_home "$init"
  new_home "$marker"
  new_home "$publication"
  : > "$concurrency/state/live.meta"
  : > "$init/state/live.meta"
  : > "$marker/state/live.meta"
  : > "$publication/state/live.meta"
  printf 'announced:downtime:driver-fixture\n' > "$marker/state/.watcher-down"
  mkdir -p "$marker/fakebin"
  cat > "$marker/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  *.watcher-down.tmp.*) exit 1 ;;
esac
exec "$REAL_MKTEMP" "$@"
SH
  chmod +x "$marker/fakebin/mktemp"
  write_hook_wrapper "$project"

  sleep 300 & holder=$!
  printf '%s\n' "$holder" >> "$HELPERS"
  mkdir "$init/state/.watcher-down.lock"
  printf '%s\n' "$holder" > "$init/state/.watcher-down.lock/pid"

  # Publish the event outside Codex only after both native matching handlers
  # have contended for ownership and the real watcher has emitted a beacon.
  (
    i=0
    while [ "$i" -lt 240 ]; do
      if [ -s "$concurrency/state/.codex-park-owner" ] \
        && grep -q '^seq=[2-9][0-9]* ' "$concurrency/state/.codex-park-owner" 2>/dev/null \
        && [ -e "$concurrency/state/.last-watcher-beat" ]; then
        printf 'done: native concurrent Stop event\n' > "$concurrency/state/live.status"
        exit 0
      fi
      sleep 0.25
      i=$((i + 1))
    done
    exit 1
  ) &
  controller=$!
  printf '%s\n' "$controller" >> "$HELPERS"

  # shellcheck disable=SC2016 # Hook-shell expansion is intentionally deferred.
  command='"$(pwd -P)"/bin/fm-codex-live-stop-wrapper.sh'
  set_stop_hooks "$project" \
    "$command concurrency-delivery $concurrency $main" \
    "$command concurrency-delivery $concurrency $main" \
    "$command init-timeout $init $main" \
    "$command marker-failure $marker $main" \
    "$command publication $publication $main"
  prompt="Reply with exactly FINAL_READY. If a watcher wake continues this turn, run FM_HOME=$concurrency FM_ROOT_OVERRIDE=$project bin/fm-wake-drain.sh, handle live.status, run its exact WAKE_ACK_REQUIRED command with those same environment values, use python3 to call pathlib.Path('$concurrency/state/live.meta').unlink(missing_ok=True), then reply exactly WAKE_HANDLED. For any other Stop-hook continuation, reply exactly FINAL_RETRY and do not run tools."
  run_codex final-combined "$project" "$main" "$prompt"

  # Preserve every native payload and callback result before an assertion can
  # fail and the disposable lab is removed by the EXIT trap.
  snapshot_home "$EVIDENCE/05-final-combined" concurrency "$concurrency"
  snapshot_home "$EVIDENCE/05-final-combined" init-timeout "$init"
  snapshot_home "$EVIDENCE/05-final-combined" marker-failure "$marker"
  snapshot_home "$EVIDENCE/05-final-combined" publication "$publication"

  wait "$controller" || fail "concurrent native Stop handlers never owned a real watcher before the event"
  awk -v pid="$controller" '$0 != pid' "$HELPERS" > "$HELPERS.tmp"
  mv "$HELPERS.tmp" "$HELPERS"
  assert_native_stops "$concurrency" 2
  assert_native_stops "$init"
  assert_native_stops "$marker"
  assert_native_stops "$publication"
  grep -q 'WAKE_HANDLED' "$EVIDENCE/05-final-combined/codex.jsonl" \
    || fail "concurrent native Stop wake did not resume the parent turn"
  [ "$(grep -R -c 'firstmate watcher wake' "$concurrency/state/hook-log"/* 2>/dev/null \
    | awk -F: '{sum += $2} END {print sum + 0}')" -eq 1 ] \
    || fail "concurrent matching Stop handlers duplicated or lost the watcher delivery"
  owner_pid=$(cat "$concurrency/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$owner_pid" ] || ! kill -0 "$owner_pid" 2>/dev/null \
    || fail "concurrent Stop supersession left a live watcher after no-work stand-down"
  [ ! -s "$init/state/.watch.lock/pid" ] \
    || fail "timeout during post-claim watcher initialization retained its watcher lock"
  [ -s "$marker/state/.watch.lock/pid" ] \
    || fail "selective recovery-marker failure discarded diagnostic watcher-lock evidence"
  grep -R -q 'WATCHER PARK RENEWAL' "$init/state/hook-log" \
    || fail "native callback did not report its bounded post-claim timeout renewal"
  grep -R -q 'WATCHER PARK FAILED' "$marker/state/hook-log" \
    || fail "native callback did not surface the driver-induced marker failure"
  grep -R -q 'state directory is not writable' "$publication/state/hook-log" \
    || fail "native callback did not bound the unwritable-state publication failure"
  printf 'ok - final native invocation proved one concurrent real-watcher delivery, post-claim cleanup, marker evidence retention, and bounded unwritable-state refusal\n'
}

if [ "${FM_CODEX_LIVE_FINAL_COMBINED:-0}" = 1 ]; then
  [ "$INVOCATIONS" -eq 4 ] \
    || fail "final-combined resume requires exactly four prior native invocations"
  run_final_combined
else
  [ "${FM_CODEX_LIVE_RESUME_AFTER_INFRA:-0}" = 1 ] || run_infrastructure_failures
  run_replacement_sessions
  run_concurrent_renewal
  run_cleanup_failures
fi

[ "$INVOCATIONS" -eq "$MAX_INVOCATIONS" ] \
  || fail "adversarial probe used $INVOCATIONS native invocations, expected $MAX_INVOCATIONS"
printf 'ok - %s adversarial continuity probe completed 5/5 isolated native invocations; evidence=%s\n' \
  "$CODEX_VERSION" "$EVIDENCE"
