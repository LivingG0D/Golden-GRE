#!/usr/bin/env bash
# shellcheck disable=SC2034 # sourced library: probe() sets P_* for its callers
# Shared helpers for the tunnel benchmark. Source this file; do not run it.
# Everything a test leaves on a server lives under $TB (/tmp/tb), uses the "tb" name prefix
# and the iptables comment "tmp-tb", so bench/cleanup.sh can remove it in one pass.

TB=/tmp/tb
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The two servers' public addresses live in bench/hosts.env (git-ignored), never in the repository.
# shellcheck disable=SC1091
[ -f "$HERE/hosts.env" ] && . "$HERE/hosts.env"
: "${IR:?set IR and TR in bench/hosts.env (copy bench/hosts.env.example)}"
: "${TR:?set IR and TR in bench/hosts.env (copy bench/hosts.env.example)}"
RESULTS=${RESULTS:-$HERE/../results}

SSHO=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5)

# rssh <host> <cmd...> -- ssh as root. Retries only when ssh itself fails (255): the IR sshd
# sometimes resets a session during key exchange, before any command has run.
rssh() {
  local h=$1 rc
  shift
  for _ in 1 2 3 4; do
    # shellcheck disable=SC2029 # the command is built on the client on purpose
    ssh "${SSHO[@]}" "root@$h" "$@"
    rc=$?
    [ "$rc" -ne 255 ] && return "$rc"
    sleep 2
  done
  return 255
}

# rput <host> <local file> <remote path>
rput() {
  rssh "$1" "mkdir -p \"\$(dirname '$3')\" && cat > '$3'" < "$2"
}

# push_remote <host> -- copy bench/remote/* and the C relay source to $TB on the server
push_remote() {
  local f
  for f in "$HERE"/remote/* "$HERE"/../relay/golden-gre-relay.c; do
    rput "$1" "$f" "$TB/$(basename "$f")"
  done
}

host_ip() { # IR|TR -> public address
  case $1 in IR) echo "$IR" ;; TR) echo "$TR" ;; esac
}

# probe <carrier> <port> <from> <to> <size> <mbit> <secs> [key=val ...]
# Runs probe.py recv on <to> and send on <from> (IR|TR) and sets P_TX P_RX P_ECHO P_PER.
probe() {
  local car=$1 port=$2 from=$3 to=$4 size=$5 mbit=$6 secs=$7 fip tip rp t
  shift 7
  fip=$(host_ip "$from")
  tip=$(host_ip "$to")
  t=$(mktemp -d)
  rssh "$tip" "python3 $TB/probe.py recv $car $tip $port $((secs + 7)) $*" > "$t/rx" 2>&1 &
  rp=$!
  sleep 3
  rssh "$fip" "python3 $TB/probe.py send $car $fip $tip $port $size $mbit $secs $*" > "$t/tx" 2>&1
  wait "$rp"
  P_TX=$(sed -n 's/^TX n=\([0-9]*\).*/\1/p' "$t/tx")
  P_ECHO=$(sed -n 's/^TX .*echoes=\([0-9]*\).*/\1/p' "$t/tx")
  P_RX=$(sed -n 's/^RX n=\([0-9]*\).*/\1/p' "$t/rx")
  P_PER=$(sed -n 's/.*persec=//p' "$t/rx")
  P_OOO=$(sed -n 's/^RX .*ooo=\([0-9]*\).*/\1/p' "$t/rx")
  rm -rf "$t"
}

# method_port <method> -- the UDP port a method's tunnel packets use (0 = not UDP)
method_port() {
  case $1 in
    gre-fou | gre-gue | ipip-fou) echo 5581 ;;
    vxlan) echo 4789 ;;
    geneve) echo 6081 ;;
    wg) echo 51821 ;;
    *) echo 0 ;; # raw IP protocols, and the relay methods, which do not need hopping
  esac
}

# method_hop_mode <method> -- zero|plain, see remote/hop.sh
method_hop_mode() {
  case $1 in wg) echo plain ;; *) echo zero ;; esac
}

# tun_up <method> [shim] -- bring up tb0 (10.77.61.1 on IR, .2 on TR) on both servers, optionally with
# source-port hopping, and start the iperf3 server on TR (10.77.61.2:5431). Undo with tun_down.
tun_up() {
  local method=$1 shim=${2:-} port out trpub irpub
  port=$(method_port "$method")
  push_remote "$TR"
  sleep 2
  push_remote "$IR"
  out=$(rssh "$TR" "IR=$IR TR=$TR bash $TB/l3.sh up $method tr") || { echo "$out"; return 1; }
  trpub=$(echo "$out" | sed -n 's/^PUB=//p')
  sleep 2
  out=$(rssh "$IR" "IR=$IR TR=$TR bash $TB/l3.sh up $method ir") || { echo "$out"; return 1; }
  irpub=$(echo "$out" | sed -n 's/^PUB=//p')
  case $method in
    wg | wg-dns | wg-icmp | wg-dns-c | wg-icmp-c)
      rssh "$TR" "IR=$IR TR=$TR bash $TB/l3.sh peer $method tr '$irpub'" > /dev/null
      sleep 2
      rssh "$IR" "IR=$IR TR=$TR bash $TB/l3.sh peer $method ir '$trpub'" > /dev/null ;;
  esac
  if [ -n "$shim" ]; then
    rssh "$TR" "bash $TB/hop.sh up $IR $port $(method_hop_mode "$method")" || return 1
    sleep 2
    rssh "$IR" "bash $TB/hop.sh up $TR $port $(method_hop_mode "$method")" || return 1
    sleep 2
  fi
  rssh "$TR" "iperf3 -s -D -B 10.77.61.2 -p 5431 --pidfile $TB/ip3.pid >/dev/null 2>&1"
}

# tun_down <method> -- remove everything tun_up created (safe to call twice)
tun_down() {
  rssh "$TR" "kill \$(cat $TB/ip3.pid) 2>/dev/null; bash $TB/hop.sh down; IR=$IR TR=$TR bash $TB/l3.sh down $1 tr" 2>&1 | sed 's/^/TR /'
  sleep 2
  rssh "$IR" "bash $TB/hop.sh down; IR=$IR TR=$TR bash $TB/l3.sh down $1 ir" 2>&1 | sed 's/^/IR /'
}
