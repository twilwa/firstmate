#!/usr/bin/env bash
# diff-run.sh <base-script> <new-script> <out-dir> <home>...: run poll from both scripts per home and NOW, compare bytes.
set -u
base=$1 new=$2 out=$3; shift 3
mkdir -p "$out"
same=0 differ=0
for home in "$@"; do
  name=$(basename "$home")
  for now in 999 1400 1500 1600 2000 real; do
    for v in base new; do
      s=$base; [ $v = new ] && s=$new
      if [ $now = real ]; then
        timeout 60 env FM_HOME="$home" "$s" poll > "$out/$name.$now.$v.out" 2> "$out/$name.$now.$v.err" < /dev/null; echo $? > "$out/$name.$now.$v.rc"
      else
        timeout 60 env FM_HOME="$home" FM_REVIEW_NOW_EPOCH=$now "$s" poll > "$out/$name.$now.$v.out" 2> "$out/$name.$now.$v.err" < /dev/null; echo $? > "$out/$name.$now.$v.rc"
      fi
    done
    if cmp -s "$out/$name.$now.base.out" "$out/$name.$now.new.out" && cmp -s "$out/$name.$now.base.rc" "$out/$name.$now.new.rc"; then
      same=$((same+1)); st=SAME
    else
      differ=$((differ+1)); st=DIFF
    fi
    printf '%-28s now=%-5s %s rc=%s/%s base=%q new=%q\n' "$name" "$now" "$st" "$(cat "$out/$name.$now.base.rc")" "$(cat "$out/$name.$now.new.rc")" "$(cat "$out/$name.$now.base.out")" "$(cat "$out/$name.$now.new.out")"
    if ! cmp -s "$out/$name.$now.base.err" "$out/$name.$now.new.err"; then printf '   stderr differs: base=%q new=%q\n' "$(cat "$out/$name.$now.base.err")" "$(cat "$out/$name.$now.new.err")"; fi
  done
done
printf 'TOTAL same=%s differ=%s\n' "$same" "$differ"
