#!/bin/bash
# shellcheck disable=SC2086 # every expansion is a plain token (addresses, ports, names)
# l3.sh <up|peer|down> <method> <ir|tr> [wg_peer_public_key]
# L3 tunnels between the two servers: device tb0, overlay 10.77.61.0/30 (IR .1, TR .2).
# native methods: gre gre-fou gre-gue ipip ipip-fou vxlan geneve wg
# relay methods (UDP goes through a relay that wraps it in a facade the path lets through):
#   wg-dns wg-icmp          WireGuard + Python relay (bench/remote/tbrelay.py, the slow baseline)
#   wg-dns-c wg-icmp-c      WireGuard + C relay (relay/golden-gre-relay.c, compiled here)
#   gre-dns-c gre-icmp-c    GRE-in-FOU on loopback + C relay (no encryption)
# "up" prints READY; the wg methods need a second step ("peer") once both public keys are known.
act=$1 method=$2 role=$3 pub=${4:-}
: "${IR:?IR not set (bench/lib.sh passes it)}" "${TR:?TR not set}"
if [ "$role" = ir ]; then L=$IR R=$TR H=1 SP=5581; else L=$TR R=$IR H=2 SP=auto; fi
FP=5581   # FOU port of the native fou/gue methods
RP=5701   # relay's local UDP port (a running golden-gre tunnel uses 5601/5599 by default: keep the benchmark apart)
LP=5698   # loopback FOU port of the gre-*-c methods
TB=/tmp/tb

facade="" impl=py
case $method in
  wg-dns) facade=dns ;;
  wg-icmp) facade=icmp ;;
  wg-dns-c | gre-dns-c) facade=dns impl=c ;;
  wg-icmp-c | gre-icmp-c) facade=icmp impl=c ;;
esac

start_relay() {
  if [ "$impl" = c ]; then
    [ -x $TB/relay-c ] || gcc -O2 -o $TB/relay-c $TB/golden-gre-relay.c || { echo "gcc failed"; exit 1; }
    nohup $TB/relay-c --facade $facade --bind $L --peer $R --local 127.0.0.1:$RP > $TB/relay.log 2>&1 &
  else
    nohup python3 $TB/tbrelay.py --facade $facade --bind $L --peer $R --local 127.0.0.1:$RP > $TB/relay.log 2>&1 &
  fi
  echo $! > $TB/relay.pid
  sleep 1
}

case $act in
up)
  ip link show tb0 >/dev/null 2>&1 && { echo "tb0 already exists, abort"; exit 1; }
  ip fou show 2>/dev/null | grep -qE "port ($FP|$LP) " && { echo "fou port $FP/$LP already in use, abort"; exit 1; }
  modprobe fou; modprobe ip_gre; modprobe ipip; modprobe vxlan; modprobe geneve; modprobe wireguard
  case $method in
    gre) ip link add tb0 type gre local $L remote $R key 41 ttl 255 ;;
    gre-fou)
      ip fou add port $FP ipproto 47
      ip link add tb0 type gre local $L remote $R key 41 ttl 255 encap fou encap-sport $SP encap-dport $FP ;;
    gre-gue)
      ip fou add port $FP gue
      ip link add tb0 type gre local $L remote $R key 41 ttl 255 encap gue encap-sport $SP encap-dport $FP ;;
    ipip) ip link add tb0 type ipip local $L remote $R ttl 255 ;;
    ipip-fou)
      ip fou add port $FP ipproto 4
      ip link add tb0 type ipip local $L remote $R ttl 255 encap fou encap-sport $SP encap-dport $FP ;;
    vxlan) ip link add tb0 type vxlan id 41 local $L remote $R dstport 4789 nolearning ;;
    geneve) ip link add tb0 type geneve id 41 remote $R dstport 6081 ;;
    gre-dns-c | gre-icmp-c)
      ip fou add port $LP ipproto 47 local 127.0.0.1
      ip link add tb0 type gre local 127.0.0.1 remote 127.0.0.1 key 41 ttl 255 encap fou encap-sport $LP encap-dport $RP ;;
    wg | wg-dns | wg-icmp | wg-dns-c | wg-icmp-c)
      ip link add tb0 type wireguard || { echo "wireguard unavailable"; exit 1; }
      k=$(wg genkey)
      echo "$k" | wg set tb0 listen-port 51821 private-key /dev/stdin
      unset k
      echo "PUB=$(wg show tb0 public-key)" ;;
    *) echo "unknown method $method"; exit 1 ;;
  esac
  ip addr add 10.77.61.$H/30 dev tb0
  # One packet per rewrite: a GSO segment would be rewritten once and split into many packets that
  # share a source port, which the path cuts after about 6.
  ethtool -K tb0 tso off gso off gro off >/dev/null 2>&1
  case $method in
    wg | wg-dns | wg-icmp | wg-dns-c | wg-icmp-c) ;;
    gre-dns-c | gre-icmp-c) start_relay; ip link set tb0 mtu 1380 up; echo READY ;;
    *) ip link set tb0 mtu 1380 up; echo READY ;;
  esac
  ;;
peer)
  o=$((3 - H))
  ep="$R:51821"
  mtu=1380
  if [ -n "$facade" ]; then
    ep="127.0.0.1:$RP"
    [ "$impl" = py ] && mtu=1300
    start_relay
  fi
  wg set tb0 peer "$pub" endpoint "$ep" allowed-ips "10.77.61.$o/32" persistent-keepalive 5
  ip link set tb0 mtu $mtu up
  echo READY
  ;;
down)
  [ -f $TB/relay.pid ] && kill "$(cat $TB/relay.pid)" 2>/dev/null
  rm -f $TB/relay.pid
  ip link del tb0 2>/dev/null
  ip fou del port $FP 2>/dev/null
  ip fou del port $LP local 127.0.0.1 2>/dev/null || ip fou del port $LP 2>/dev/null
  echo "l3 down: tb0=$(ip -br link | grep -c '^tb0') fou=$(ip fou show 2>/dev/null | grep -cE "port ($FP|$LP) ") relay=$(pgrep -fc 'tb/(relay-c|tbrelay.py)')"
  ;;
esac
