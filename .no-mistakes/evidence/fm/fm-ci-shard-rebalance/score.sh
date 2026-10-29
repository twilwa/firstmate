#!/usr/bin/env bash
# score.sh <lanes-dir> <prefix> : for each run, sum measured per-script duration_ms per lane
D=/tmp/fm-ci-timing; L=$1; P=$2
for run in 40664798225 40673507764 40703025845 40796972623 40768416410 40805050743; do
  find $D/$run -name 'fm-test-timing-portable-*.json' -exec jq -r '.scripts[] | [.path,.duration_ms,.exit]|@tsv' {} \; > $D/m-$run.tsv
  par=""; for l in 1 2; do s=$(awk 'NR==FNR{m[$1]=$2;next} {if(!($1 in m)) miss++; t+=m[$1]} END{printf "%d%s", t/1000, (miss?"(miss"miss")":"")}' $D/m-$run.tsv $L/${P}portable-parallel-$l.txt); par="$par $s"; done
  ser=""; mn=999999; mx=0; for k in $(seq 1 11); do s=$(awk 'NR==FNR{m[$1]=$2;next} {t+=m[$1]} END{printf "%d", t/1000}' $D/m-$run.tsv $L/${P}s$k.txt); ser="$ser $s"; ((s<mn))&&mn=$s; ((s>mx))&&mx=$s; done
  set -- $par; pa=${1%%(*}; pb=${2%%(*}; pmx=$((pa>pb?pa:pb)); pmn=$((pa<pb?pa:pb))
  printf "%s parallel=[%s] spread=%d%%  serial=[%s] min=%d max=%d spread=%d%%\n" $run "$par" $(( (pmx-pmn)*100/pmx )) "$ser" $mn $mx $(( (mx-mn)*100/mx ))
done
