#!/bin/bash
# hop.sh up <peer_ip> <udp_port> <zero|plain> [nports] | down
# Per-packet UDP source-port hopping for packets this host sends to <peer_ip>:<udp_port>,
# and no conntrack for that traffic in either direction (a new port per packet would flood it).
# The path cuts every UDP flow (5-tuple) after about 6 packets; a new source port is a new flow.
# Checksums: after a port rewrite nft fixes the UDP checksum incrementally, which is wrong when the
# tunnel sends a zero checksum (FOU, GUE, VXLAN, Geneve default; kernel 6.8 turns 0 into garbage) or when
# the outer checksum was already computed for an offloaded inner packet. "zero" therefore resets the
# checksum field to 0 (valid for IPv4 UDP) after the rewrite. "plain" is for tunnels whose checksum is
# still partial at this hook (WireGuard), where the stack fills it in later.
# nft cannot do arithmetic on a port, so the random port comes from numgen indexing a map.
case $1 in
up)
  peer=$2 port=$3 mode=$4 n=${5:-20000}
  fix=""
  [ "$mode" = zero ] && fix="@th,48,16 set 0"
  nft delete table inet tbhop 2>/dev/null
  {
    echo "table inet tbhop {"
    echo "  map sp { type mark : inet_service; elements = {"
    awk -v n="$n" 'BEGIN { for (i = 0; i < n; i++) printf "%d : %d%s\n", i, 10000 + i, (i < n - 1) ? "," : "" }'
    echo "  } }"
    echo "  chain out { type filter hook output priority raw; policy accept;"
    echo "    ip daddr $peer udp dport $port udp sport set numgen random mod $n map @sp $fix notrack"
    echo "  }"
    echo "  chain in { type filter hook prerouting priority raw; policy accept;"
    echo "    ip saddr $peer udp dport $port notrack"
    echo "  }"
    echo "}"
  } | nft -f - && echo "hop up: $peer:$port, $n source ports, checksum $mode"
  ;;
down)
  nft delete table inet tbhop 2>/dev/null
  echo "hop down: tables=$(nft list tables 2>/dev/null | grep -c tbhop)"
  ;;
esac
