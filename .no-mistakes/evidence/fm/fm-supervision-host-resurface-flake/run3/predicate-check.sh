#!/bin/bash
# Adversarial check of the HEAD resurface predicate and elapsed-time wait, extracted verbatim from the test file.
W=$1; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
eval "$(sed -n '/^resurface_delivered_since() {/,/^}/p;/^wait_for_host_event() {/,/^}/p' "$W/tests/fm-supervision-host.test.sh")"
h=$T/h; mkdir -p $h/state; L=$h/state/.watch-deliveries.log
chk(){ if resurface_delivered_since "$h" "$2"; then r=accepted; else r=rejected; fi; printf '%-55s previous=%s -> %s\n' "$1" "$2" "$r"; }
chk "no delivery log yet" 0
printf '1\tw\tcheck: rearm-resurface\n' > $L; chk "only a previous park's resurface row" 1
printf '2\tw\tcheck: stale-beacon\n' >> $L; chk "new row is an unrelated wake (beacon/other)" 1
printf '3\tw\tcheck: rearm-resurface-extra\n' >> $L; chk "new row only prefix-matches the resurface reason" 1
printf '4\tw\tcheck: rearm-resurface\n' >> $L; chk "new row is this park's resurface" 1
echo "--- wait_for_host_event bound (elapsed time, not poll count)"
s=$SECONDS; wait_for_host_event 3 false; echo "never-true predicate: rc=$? after $((SECONDS-s))s (bound 3s)"
f=$T/ev; (sleep 2; : > $f) & s=$SECONDS; wait_for_host_event 10 test -e $f; echo "event at ~2s: rc=$? after $((SECONDS-s))s (bound 10s)"
