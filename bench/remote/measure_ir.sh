#!/bin/bash
# measure_ir.sh <overlay_peer> <epoch> -- run on IR: ping, iperf3 TCP (down, up, 4 flows) and UDP through
# the overlay. The iperf3 server runs on TR at <overlay_peer>:5431. Down = TR to IR.
# shellcheck disable=SC1091
. /tmp/tb/common.sh
T=$1
T0=$2
ip3() { timeout "$1" iperf3 -c "$T" -p 5431 "${@:2}" 2>&1; }
rate() { awk '/receiver/ {r = $(NF-2) " " $(NF-1)} /sender/ {t = $(NF-1)} END {print r, "retr=" t}'; }

p=$(ping -c 20 -i 0.2 -W 2 -q "$T" | grep -E 'packet loss|rtt' | sed -E 's/^[0-9]+ packets transmitted, //; s/, time [0-9]+ms//; s/rtt min.avg.max.mdev = //' | paste -sd' ')
echo "ping: $p"
case $p in *"100% packet loss"*) echo "tcp_down: FAIL (no ping)"; exit 0 ;; esac
waitfor "$T0"
ip3 25 -t 8 -R > /tmp/tb/down.out &
sleep 2
echo "tcp_down_cpu: $(cpu 6)"
wait
echo "tcp_down: $(rate < /tmp/tb/down.out)"
echo "tcp_up: $(ip3 25 -t 8 | rate)"
echo "tcp_down_4flows: $(ip3 25 -t 8 -R -P 4 | awk '/SUM.*receiver/ {r = $(NF-2) " " $(NF-1)} /SUM.*sender/ {t = $(NF-1)} END {print r, "retr=" t}')"
echo "udp_30M_down: $(ip3 25 -u -b 30M -t 5 -R | awk '/receiver/ {print $(NF-6), $(NF-5), "jitter", $(NF-3), $(NF-2), "loss", $(NF-1)}' | tail -1)"
rm -f /tmp/tb/down.out
