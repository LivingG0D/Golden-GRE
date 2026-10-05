#!/usr/bin/env bash
# Measure several tunnel methods one after another and print one summary row each.
# usage: bench/matrix.sh <method>[:shim] ...
#   e.g. bench/matrix.sh gre gre-fou gre-fou:shim wg wg-dns wg-icmp
# Raw logs go to results/raw/, the table to results/matrix-<date>.tsv.
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -gt 0 ] || { sed -n '2,5p' "$0"; exit 1; }
stamp=$(date +%Y%m%d-%H%M)
mkdir -p "$RESULTS/raw"
out=$RESULTS/matrix-$stamp.tsv

field() { # log key -> value after "key: "
  sed -n "s/^$2: //p" "$1" | head -1
}

printf 'method\tping\ttcp_down\ttcp_up\ttcp_down_4flows\tudp_30M_down\tcpu_ir_tcp_down\tcpu_tr\n' | tee "$out"
for spec in "$@"; do
  m=${spec%%:*}
  shim=""
  [ "$spec" != "$m" ] && shim=${spec#*:}
  log=$RESULTS/raw/$stamp-$m${shim:+-$shim}.log
  bash "$(dirname "${BASH_SOURCE[0]}")/measure.sh" "$m" "$shim" > "$log" 2>&1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$m${shim:+ +hop}" \
    "$(field "$log" ping | sed 's/ packet loss.*//; s/ received, /\/20 ok, loss /; s/^/rx /' | cut -c1-40)" \
    "$(field "$log" tcp_down)" "$(field "$log" tcp_up)" "$(field "$log" tcp_down_4flows)" \
    "$(field "$log" udp_30M_down)" "$(field "$log" tcp_down_cpu)" \
    "$(sed -n 's/^TR cpu: //p' "$log" | head -1)" | tee -a "$out"
  sleep 5
done
echo "saved: $out"
