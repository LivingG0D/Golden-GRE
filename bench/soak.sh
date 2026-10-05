#!/usr/bin/env bash
# Sustained transfer through one tunnel: per-10-second throughput plus UDP drop counters on both servers.
# Catches what a short test cannot: the path learning the disguise and cutting it, or a relay overflowing.
# usage: bench/soak.sh <method> [secs]      default 300 s, TR to IR (the download direction)
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

method=${1:?method}
secs=${2:-300}
trap 'tun_down "$method"' EXIT

drops() { # host label -> UDP errors since the last nstat -n
  rssh "$1" "nstat -z 2>/dev/null | awk '/UdpInErrors|UdpRcvbufErrors|UdpSndbufErrors|UdpInCsumErrors/ {printf \"%s=%s \", \$1, \$2}'; echo" | sed "s/^/$2 /"
}

tun_up "$method" || exit 1
sleep 2
rssh "$IR" "nstat -n >/dev/null"
sleep 1
rssh "$TR" "nstat -n >/dev/null"
echo "== $method soak, $secs s, TR to IR (Mbit/s per 10 s)"
rssh "$IR" "timeout $((secs + 30)) iperf3 -c 10.77.61.2 -p 5431 -R -t $secs -i 10 2>&1 | awk '/sec/ && !/sender|receiver/ {printf \"%s \", \$7} /sender|receiver/ {print; }'"
echo
sleep 2
for h in "$IR" "$TR"; do
  rssh "$h" "echo \"\$(hostname -s) relay sockets (d = packets dropped by that socket):\"; ss -uamp '( sport = :53 or sport = :5701 )' 2>/dev/null | grep -oE 'tbrelay|skmem:\([^)]*\)' | paste -sd' ' | sed 's/tbrelay /\n  /g'"
  sleep 2
done
drops "$IR" IR
sleep 2
drops "$TR" TR
