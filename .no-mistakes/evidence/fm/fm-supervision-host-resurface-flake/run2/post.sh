#!/bin/bash
# Post-process run 2: live pass lines, live case order vs base, per-case retirement table.
E=/home/firstmate/.no-mistakes/evidence/01M625AZYW97Z6V19RD7QP18TG/run2
W=/home/firstmate/.no-mistakes/worktrees/8be14fbb8fb5/01M625AZYW97Z6V19RD7QP18TG
sed -n 's/^ok - //p' $E/output.log > $E/live-pass-lines.txt
grep -c '^not ok' $E/output.log > $E/not-ok-count.txt
python3 -I $E/map_live_order.py $W/tests/fm-supervision-host.test.sh $E/output.log $E/live-order-check.txt > $E/live-case-order.txt 2> $E/live-order-summary.txt
diff $E/base-case-order.txt $E/live-case-order.txt > $E/live-vs-base-case-order.diff; echo "live_vs_base_case_order_diff_rc=$?" >> $E/live-order-summary.txt
grep -v '^/tmp' $E/sampler.log | grep '^t=' > $E/sampler.clean.log
awk '{for(i=1;i<=NF;i++){split($i,a,"=");v[a[1]]=a[2]} k=v["ok"]; n[k]++; if(!(k in mn)||v["tasks"]<mn[k])mn[k]=v["tasks"]; if(v["tasks"]>mx[k])mx[k]=v["tasks"]; last[k]=v["tasks"]; lw[k]=v["watcher_or_host_procs"]; if(!(k in ord)){ord[k]=++c; keys[c]=k}}
 END{print "ok_count_at_sample\tsamples\tmin_tasks\tmax_tasks\tlast_tasks\tlast_watcher_or_host_procs"; for(j=1;j<=c;j++){k=keys[j]; print k"\t"n[k]"\t"mn[k]"\t"mx[k]"\t"last[k]"\t"lw[k]}}' $E/sampler.clean.log > $E/retirement-per-case.tsv
awk -F'\t' 'NR>1{if($4>m)m=$4; s+=$6; c++} END{print "max_scope_tasks="m" rows="c}' $E/retirement-per-case.tsv
