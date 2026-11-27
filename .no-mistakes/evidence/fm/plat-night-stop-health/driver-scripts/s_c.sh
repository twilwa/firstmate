set -u
. /tmp/fm-nc-driver/common.sh
ledger() {  # <lab> <num> <outcome> <rec_epoch> <base_ref> [risk] [created]
  local lab=$1 num=$2 out=$3 rec=$4 br=$5 risk=${6:-low} created=${7:-$(( $4 - 600 ))} ready=allowed
  [ "$out" = passed ] || ready=blocked
  mkdir -p "$lab/data/pr-review-ledger"
  jq -cn --arg num "$num" --arg out "$out" --arg ready "$ready" --arg br "$br" --arg risk "$risk" --argjson rec "$rec" --argjson created "$created" '
   {schema:"firstmate-pr-review-ledger.v1",task:("t-"+$num),url:("https://github.com/example-org/labrepo/pull/"+$num),current_head:("a"*40),
    generations:[{head:("a"*40),created_epoch:$created,risk:{level:$risk,reason:"lab"},checkpoints:[],review_items:[],attestations:[],final_disposition:null,
      merge_decision:{decision:"merge",verified_head:("a"*40),verified_epoch:($rec-300)},
      post_merge_verifications:(if $out=="none" then [] else [{applicability:"browser",head:("a"*40),outcome:$out,ready_for_qa:$ready,recorded_epoch:$rec,base_ref:$br}] end)}]}' \
   > "$lab/data/pr-review-ledger/github--example-org--labrepo--$num.json"
}
LAB=$(mklab); fakegh "$LAB" 4000; echo "lab home: $LAB"; date
nc "$LAB" start
S=$(jq -r .started_epoch "$LAB/state/night-active.json")
say "S10 failed post-merge on dev recorded BEFORE the night (still latest) + passed on main later -> dev stays red, merges blocked, no reserve-flag"
ledger "$LAB" 101 failed $((S-1800)) dev
ledger "$LAB" 102 passed $((S-60)) main
nc "$LAB" check --json | tee "$LAB/v.json" | summ
jq -c '.conditions.dev_health.details.failed_targets' "$LAB/v.json"
jq -c '{verdict,allow,history:[.history[]|{condition,first_tripped_at,last_tripped_at}]}' "$LAB/state/night-stop.json"; ls "$LAB/state/night.reserve" 2>&1
sleep 2
say "S10 a later passing post-merge on dev -> latest wins: continue, stop record snapshot follows recovery, history kept"
ledger "$LAB" 103 passed $(( $(date +%s) - 1 )) dev
nc "$LAB" check --json | summ
jq -c '{verdict,allow,history_len:(.history|length),last_checked_at}' "$LAB/state/night-stop.json"
sleep 2
say "S10 dev fails again -> a second history entry (recovery not merged away)"
ledger "$LAB" 101 failed $(( $(date +%s) - 1 )) dev
nc "$LAB" check --json | summ
jq -c '[.history[]|{first_tripped_epoch,last_tripped_epoch}]' "$LAB/state/night-stop.json"
rm -f "$LAB"/data/pr-review-ledger/*.json

say "S12 validation cap: 2 high-risk PR generations created tonight (+1 low-risk, +1 high pre-night) -> stop_validation only"
ledger "$LAB" 201 none 0 dev high $((S+1))
ledger "$LAB" 202 none 0 dev high $((S+2))
ledger "$LAB" 203 none 0 dev low $((S+3))
ledger "$LAB" 204 none 0 dev high $((S-3600))
nc "$LAB" check --json | tee "$LAB/v.json" | summ
jq -c '.conditions.validation_cap.details' "$LAB/v.json"
say "S12 only 1 high-risk tonight -> continue"
rm -f "$LAB/data/pr-review-ledger/github--example-org--labrepo--202.json"
nc "$LAB" check --json | summ

say "S7 hc-guard while night active: real bin/fm-install-hc.sh refuses before downloading"
DEST=$(mktemp -d); env -u NO_MISTAKES_GATE FM_HOME="$LAB" "$WT/bin/fm-install-hc.sh" "$DEST"; echo "install rc=$?"; echo "dest contents: [$(ls -A "$DEST")]"
nc "$LAB" hc-guard; echo "hc-guard rc=$?"
say "S7 adversarial: corrupt state/night-active.json -> guard still refuses (fails closed)"
cp "$LAB/state/night-active.json" "$LAB/na.bak"; printf '{bad' > "$LAB/state/night-active.json"
nc "$LAB" hc-guard; echo "hc-guard rc=$?"
env -u NO_MISTAKES_GATE FM_HOME="$LAB" "$WT/bin/fm-install-hc.sh" "$DEST"; echo "install rc=$?"; echo "dest contents: [$(ls -A "$DEST")]"
mv "$LAB/na.bak" "$LAB/state/night-active.json"
nc "$LAB" end >/dev/null
say "S7 after end: hc-guard allows (installer itself NOT run, to avoid a real download)"
nc "$LAB" hc-guard; echo "hc-guard rc=$?"
rmdir "$DEST"; rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
