#!/usr/bin/env bash
# Localize a drop: count packets on the sender's NIC (egress) and the receiver's NIC (ingress)
# while probe.py sends one carrier. Sender NIC high + receiver NIC low = dropped in transit.
# usage: bench/localize.sh <carrier> <from IR|TR> <to IR|TR> [secs] [mbit]
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

car=${1:?carrier: udp or an IP protocol number}
from=${2:?from IR|TR}
to=${3:?to IR|TR}
secs=${4:-5}
mbit=${5:-20}
port=47123
fip=$(host_ip "$from")
tip=$(host_ip "$to")
if [ "$car" = udp ]; then flt="udp port $port"; else flt="ip proto $car"; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cap() { # host direction -> number of matching packets seen on eth0
  rssh "$1" "timeout $((secs + 8)) tcpdump -nn -q -l -i eth0 -Q $2 '$flt and src host $fip and dst host $tip' 2>/dev/null | wc -l"
}

push_remote "$fip"
push_remote "$tip"
cap "$tip" in > "$tmp/in" &
sleep 1
cap "$fip" out > "$tmp/out" &
sleep 1
rssh "$tip" "python3 $TB/probe.py recv $car $tip $port $((secs + 7))" > "$tmp/rx" 2>&1 &
sleep 3
rssh "$fip" "python3 $TB/probe.py send $car $fip $tip $port 1200 $mbit $secs" > "$tmp/tx" 2>&1
wait
echo "$car $from>$to  sender NIC out: $(tr -d ' \r\n' < "$tmp/out")  receiver NIC in: $(tr -d ' \r\n' < "$tmp/in")  | $(cat "$tmp/tx") | $(cat "$tmp/rx")"
