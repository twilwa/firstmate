set -u
. /tmp/fm-nc-driver/common.sh
LAB=$(mklab); fakegh "$LAB" 4000; mkdir -p "$LAB/proc"; cp /proc/meminfo "$LAB/proc/meminfo"
nc "$LAB" start >/dev/null; T0=$(date +%s)
run() { NC_EXTRA_ENV="FM_PROC_ROOT_OVERRIDE=$LAB/proc FM_NIGHT_NOW_EPOCH=$1" nc "$LAB" check --json | jq -c '{verdict,allow:{dispatch:.allow.dispatch,validation:.allow.validation},host_load:(.conditions.host_load|{status,reason,since:.details.high_load_since_epoch,elapsed:.details.elapsed_seconds})}'; }
say "S13 synthetic loadavg 24.00 (not above 24) at T0"; printf '24.00 20 18 1/100 1\n' > "$LAB/proc/loadavg"; run $((T0+5))
say "S13 loadavg 30 at T0+10s (timer starts)"; printf '30.00 20 18 1/100 1\n' > "$LAB/proc/loadavg"; run $((T0+10))
say "S13 loadavg 30 at T0+5min (still under 10min)"; run $((T0+310))
say "S13 loadavg 30 at T0+10min+10s -> stop_dispatch, validations stopped"; run $((T0+620))
say "S13 load recovers to 5 -> continue"; printf '5.00 20 18 1/100 1\n' > "$LAB/proc/loadavg"; run $((T0+680))
nc "$LAB" end >/dev/null; rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
