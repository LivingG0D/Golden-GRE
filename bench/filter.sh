#!/usr/bin/env bash
# Characterize what the IPv4 path cuts. Every experiment uses its own UDP port so one flow
# cannot poison the next.
# usage: bench/filter.sh basic|expiry|rate|icmp|mimic|sustain [from] [to]      default direction: IR TR
#   basic   rate / size / echo / source-port hopping at a glance
#   expiry  does a flow's packet budget come back after an idle gap?
#   rate    how fast can new flows (source-port hops) be created?
#   icmp    ICMP echo as a carrier: size and rate sweep (replies counted as echoes)
#   mimic   protocol disguises: DNS-shaped UDP, unsolicited ICMP echo replies
#   sustain the disguises that pass, at 20 and 50 Mbit/s for 20 s
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

set_name=${1:?basic|expiry|rate|icmp|mimic|sustain}
from=${2:-IR}
to=${3:-TR}
port=47200
car=udp

exp() { # name size mbit secs [key=val ...]
  local name=$1 size=$2 mbit=$3 secs=$4
  shift 4
  port=$((port + 1))
  probe "$car" "${XPORT:-$port}" "$from" "$to" "$size" "$mbit" "$secs" "$@"
  printf '%-34s tx=%-6s rx=%-6s ooo=%-5s echoes=%-5s persec=%s\n' "$name" "${P_TX:--}" "${P_RX:--}" "${P_OOO:--}" "${P_ECHO:--}" "${P_PER:--}"
}

push_remote "$(host_ip "$from")"
push_remote "$(host_ip "$to")"
echo "== $set_name: udp $from>$to"
case $set_name in
  basic)
    exp "1200B    10 pps one-way" 1200 0.096 10
    exp "1200B   100 pps one-way" 1200 0.96 10
    exp " 100B   100 pps one-way" 100 0.08 10
    exp "1200B   100 pps echo"    1200 0.96 10 echo=1
    exp "1200B   100 pps hop=1"   1200 0.96 10 hop=1
    exp "1200B  2000 pps hop=6"   1200 19.2 5 hop=6
    ;;
  expiry)
    exp "6 pkts, idle 10 s, x3"  1200 0.96 60 count=18 stall=6:10
    exp "6 pkts, idle 30 s, x3"  1200 0.96 90 count=18 stall=6:30
    exp "6 pkts, idle 90 s, x2"  1200 0.96 150 count=12 stall=6:90
    ;;
  rate)
    exp "hop=1  1000 pps"  1200 9.6 5 hop=1
    exp "hop=1  2000 pps"  1200 19.2 5 hop=1
    exp "hop=1  5000 pps"  1200 48 5 hop=1
    exp "hop=3  5000 pps"  1200 48 5 hop=3
    exp "hop=6 10000 pps"  1200 96 5 hop=6
    ;;
  sustain)
    XPORT=53 exp "-> udp/53 DNS query 20M x20s" 1300 20 20 dns=q
    XPORT=53 exp "-> udp/53 DNS query 50M x20s" 1300 50 20 dns=q
    car=icmp
    exp "icmp reply(0) 20M x20s" 1300 20 20 itype=0
    exp "icmp reply(0) 50M x20s" 1300 50 20 itype=0
    ;;
  mimic)
    XPORT=53 exp "-> udp/53 plain payload (control)" 1100 10 5
    XPORT=53 exp "-> udp/53 DNS query shape"        1100 10 5 dns=q
    XPORT=53 exp "-> udp/53 DNS TXT response shape" 1100 10 5 dns=r
    exp "udp/53 -> client port, DNS response" 1100 10 5 dns=r sport=53
    car=icmp
    exp "icmp echo reply (type 0) 10M"  1200 10 5 itype=0
    exp "icmp echo request (type 8) 10M" 1200 10 5 itype=8
    ;;
  icmp)
    car=icmp
    exp "icmp 1200B   2 Mbit/s"  1200 2 5
    exp "icmp 1200B  20 Mbit/s"  1200 20 5
    exp "icmp 1200B  50 Mbit/s"  1200 50 5
    exp "icmp  100B   1 Mbit/s"  100 1 5
    exp "icmp  100B   5 Mbit/s"  100 5 5
    exp "icmp 1200B  20 Mbit/s x20 s" 1200 20 20
    ;;
esac
