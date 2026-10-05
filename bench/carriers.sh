#!/usr/bin/env bash
# Map which IPv4 carriers survive between IR and TR, in both directions.
# Uses bench/remote/probe.py (UDP and raw IP protocols) and ping, so no TCP runs between the servers.
# usage: bench/carriers.sh [secs] [mbit]     default: 5 s at 20 Mbit/s, 1200-byte packets
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SECS=${1:-5}
MBIT=${2:-20}
SIZE=1200
UDP_PORTS="53 123 443 500 4500 4789 51821 47123"
RAW_PROTOS="4 41 47 50 51 94 115 132 136 137 143 253"

mkdir -p "$RESULTS"
OUT=$RESULTS/carriers-$(date +%Y%m%d-%H%M).tsv

row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" | tee -a "$OUT"; }

carrier() { # carrier port from to
  local pct
  probe "$1" "$2" "$3" "$4" "$SIZE" "$MBIT" "$SECS"
  if [ -z "$P_TX" ] || [ -z "$P_RX" ]; then pct=ERR; else pct="$((P_RX * 100 / P_TX))%"; fi
  row "$1" "$2" "$3>$4" "${P_TX:--}" "${P_RX:--}" "$pct" "${P_PER:--}"
}

icmp() { # from to -- 300 echo requests of 1000 bytes, 10 ms apart
  local from=$1 to=$2 fip tip line tx rx
  fip=$(host_ip "$from")
  tip=$(host_ip "$to")
  line=$(rssh "$fip" "ping -c 300 -i 0.01 -s 1000 -q -W 2 -I $fip $tip" 2>&1 | grep 'packets transmitted')
  tx=$(echo "$line" | sed -n 's/^\([0-9]*\) packets.*/\1/p')
  rx=$(echo "$line" | sed -n 's/.* \([0-9]*\) received.*/\1/p')
  row icmp - "$from>$to" "${tx:--}" "${rx:--}" "$([ -n "$tx" ] && echo "$((rx * 100 / tx))%" || echo ERR)" -
}

push_remote "$IR"
push_remote "$TR"
row carrier port dir tx rx delivered persec
for pair in "IR TR" "TR IR"; do
  read -r from to <<< "$pair"
  icmp "$from" "$to"
  for p in $UDP_PORTS; do carrier udp "$p" "$from" "$to"; done
  for p in $RAW_PROTOS; do carrier "$p" 0 "$from" "$to"; done
done
echo "saved: $OUT"
