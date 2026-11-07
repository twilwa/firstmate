. /tmp/fm-live-scripts/lib.sh
PATH=${PATH#"$SHIM:"}; hash -r
for k in 1 2 3; do for t in base:/tmp/fm-base.E2953p head:/tmp/fm-headcopy.87Irf8; do
  n=${t%%:*}; r=${t#*:}
  new_pair >/dev/null
  printf '## In flight\n\n## Queued\n- [ ] t-%s - timing item (repo: alpha)\n\n## Done\n' "$k" > "$MAIN/data/backlog.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$SUB/data/backlog.md"
  s=$(date +%s.%N)
  FM_HOME="$MAIN" TMUX_TMPDIR="$TD" "$r/bin/fm-backlog-handoff.sh" design "t-$k" >/dev/null 2>&1; rc=$?
  e=$(date +%s.%N)
  printf '%s run%s exit=%s secs=%.2f load=%s\n' "$n" "$k" "$rc" "$(echo "$e - $s" | bc)" "$(cut -d' ' -f1 /proc/loadavg)"
done; done
