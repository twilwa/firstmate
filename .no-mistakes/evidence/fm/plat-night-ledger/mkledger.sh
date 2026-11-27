#!/usr/bin/env bash
# mkledger <home> <n> <head> <decision_epoch> <risk> [post-merge-json] [extra-jq]
set -eu
home=$1 n=$2 head=$3 epoch=$4 risk=$5 post=${6:-[]}
jq -n --arg url "https://github.com/twilwa/firstmate/pull/$n" --arg head "$head" --argjson epoch "$epoch" \
  --arg risk "$risk" --argjson post "$post" '{
  schema:"firstmate-pr-review-ledger.v1",task:"lab",url:$url,current_head:$head,
  generations:[{head:$head,risk:{level:$risk,reason:"lab fixture"},
    review_items:[{kind:"top-level",id:"1",author:"sourcery-ai",disposition:"addressed",evidence:"e"},
                  {kind:"inline",id:"2",author:"coderabbitai",disposition:"addressed",evidence:"e"}],
    attestations:[{kind:"no-mistakes",head:$head,model:"claude-opus-5-5",evidence:"run"}],
    merge_decision:{decision:"merge",reviewed_head:$head,verified_head:$head,verified_epoch:$epoch,
      allowed_red_check:null,allowed_red_checks:[]},
    post_merge_verifications:$post}]}' > "$home/data/pr-review-ledger/github--twilwa--firstmate--$n.json"
