#!/usr/bin/env bash
# Bring up one kernel L3 tunnel between the servers, optionally with source-port hopping, measure it,
# and tear everything down again.
# usage: bench/measure.sh <method> [shim]     methods: see remote/l3.sh
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

method=${1:?method}
shim=${2:-}
trap 'tun_down "$method"' EXIT

echo "== $method ${shim:+with source-port hopping}"
tun_up "$method" "$shim" || exit 1
sleep 2
t0=$(($(date +%s) + 30))
rssh "$TR" "bash $TB/cpu_at.sh $((t0 + 2)) 6 | sed 's/^/TR /'" > /tmp/tbcpu.$$ 2>&1 &
cp=$!
rssh "$IR" "bash $TB/measure_ir.sh 10.77.61.2 $t0"
wait "$cp"
cat /tmp/tbcpu.$$
rm -f /tmp/tbcpu.$$
