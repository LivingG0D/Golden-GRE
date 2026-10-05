#!/usr/bin/env bash
# Remove everything the benchmark can leave on a server (tb0, its FOU ports, relays, iperf3 test servers,
# the tbhop nft table, tmp-tb firewall rules, /tmp/tb) and report which Golden GRE tunnels are running.
# It touches only benchmark names and ports, never a golden-gre@ tunnel.
# usage: bench/cleanup.sh
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

remote() {
  cat <<'EOF'
echo "== $(hostname -s)"
ip link del tb0 2>/dev/null
for p in 5581 5698; do ip fou del port $p 2>/dev/null; ip fou del port $p local 127.0.0.1 2>/dev/null; done
pkill -f 'tb/(relay-c|tbrelay.py)' 2>/dev/null
pkill -f 'iperf3 -s -D -B 10.77.61' 2>/dev/null
pkill -f 'tb/probe.py' 2>/dev/null
nft delete table inet tbhop 2>/dev/null
iptables -S INPUT | grep tmp-tb | sed 's/^-A/-D/' | while read -r r; do iptables $r; done
rm -rf /tmp/tb
echo "left over: tb0=$(ip -br link | grep -c '^tb0') fou=$(ip fou show 2>/dev/null | grep -cE 'port (5581|5698) ') procs=$(pgrep -fc 'tb/(relay-c|tbrelay.py|probe.py)') nft=$(nft list tables 2>/dev/null | grep -c tbhop) rules=$(iptables -S INPUT | grep -c tmp-tb) iperf3=$(pgrep -cx iperf3)"
echo "golden-gre tunnels: $(systemctl list-units 'golden-gre@*' --no-legend 2>/dev/null | awk '{print $1 "=" $3}' | paste -sd' ')"
EOF
}

rssh "$IR" bash -s < <(remote)
sleep 3
rssh "$TR" bash -s < <(remote)
