#!/usr/bin/env bash
. "$1"; shift
for t in "$@"; do echo "=== $t"; "$t" || { echo "FAILED: $t"; exit 1; }; done
echo "ALL SELECTED PASSED"
