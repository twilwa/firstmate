set -u
. /tmp/fm-nc-driver/common.sh
LAB=$(mklab); echo "lab home: $LAB"; date
say "S1 start a night (window 12:00-21:00 America/Los_Angeles, real clock) and run live check --json with REAL gh rate_limit + REAL /proc load"
nc "$LAB" start; echo "start rc=$?"
jq -c '{schema,started_at,window,hc_target,created_reserve_flags}' "$LAB/state/night-active.json"
out=$(nc "$LAB" check --json); echo "check rc=$?"
printf '%s\n' "$out" | summ
printf '%s\n' "$out" | jq -c '{gh:.conditions.github_api.details, load:.conditions.host_load.details, quota:.conditions.claude_quota.status, hc:.conditions.hc_core.status, night_started_epoch}'
say "S1b human-readable check"
nc "$LAB" check; echo "rc=$?"

say "S2 Claude 5h at 20% (<25) -> stop_claude"
quota "$LAB" 20 70; nc "$LAB" check --json | summ
say "S2 Claude weekly at 25% exactly (strict <) -> continue"
quota "$LAB" 80 25; nc "$LAB" check --json | summ
say "S2 Claude weekly at 11% (<12) -> stop_dispatch"
quota "$LAB" 80 11; nc "$LAB" check --json | summ
say "S2 stale reading -> unknown / stop_dispatch"
quota "$LAB" 80 70 true; nc "$LAB" check --json | summ
say "S2 adversarial: config tries to weaken floor to 20 -> rejected, fails closed"
quota "$LAB" 80 70; cp "$LAB/config/night-check" "$LAB/nc.bak"; echo "claude-stop-claude-pct 20" >> "$LAB/config/night-check"
nc "$LAB" check --json | summ
mv "$LAB/nc.bak" "$LAB/config/night-check"
say "S2 adversarial: quota-axi emits garbage -> unknown / stop_dispatch"
printf '#!/usr/bin/env bash\necho not-json\n' > "$LAB/fakebin/quota-axi"; nc "$LAB" check --json | summ; quota "$LAB" 80 70

say "S3 GitHub core remaining 999 (<1000) -> stop_dispatch, no reserve-flag (level)"
fakegh "$LAB" 999; nc "$LAB" check --json | summ; ls -la "$LAB/state/night.reserve" 2>&1
say "S3 GitHub core remaining 1000 -> continue (recovered level)"
fakegh "$LAB" 1000; nc "$LAB" check --json | summ
say "S3 adversarial: gh api fails -> unknown / stop_dispatch"
printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/fakebin/gh"; nc "$LAB" check --json | summ
rm -f "$LAB/fakebin/gh"

say "S8 end: stored verdict marked inactive, two_hour_default false, history preserved; verdict --json serves it"
nc "$LAB" end; echo "end rc=$?"
ls "$LAB/state/night-active.json" 2>&1
nc "$LAB" verdict --json | jq -c '{verdict,night_active,allow,tripped:[.tripped[].condition],checked_at}'
say "S8 start again clears prior-night verdict"
nc "$LAB" start >/dev/null; echo "start rc=$?"; nc "$LAB" verdict --json; echo "verdict rc=$? (expect 1: no verdict yet)"
nc "$LAB" end >/dev/null

say "S6 check with NO active night but past window end (cfg window 12:00-13:00) -> end_night, no reserve-flag, two_hour_default false"
sed -i 's/^last-dispatch .*/last-dispatch 12:30/; s/^window-end .*/window-end 13:00/' "$LAB/config/night-check"
nc "$LAB" check --json | summ; ls "$LAB/state/night.reserve" 2>&1
say "S6 check with NO active night inside window -> two_hour_default false (no live night)"
sed -i 's/^last-dispatch .*/last-dispatch 20:00/; s/^window-end .*/window-end 21:00/' "$LAB/config/night-check"
nc "$LAB" check --json | summ
rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
