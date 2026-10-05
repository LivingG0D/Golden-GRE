#!/usr/bin/env bash
# End-to-end test: two network namespaces joined by a veth pair stand in for two servers. Brings real
# tunnels up with scripts/golden-gre-up.sh, runs the relays, moves data across, checks the firewall
# state and the health check, then tears down and checks nothing is left behind. Also covers a second
# tunnel on the same hosts, the icmp facade, and every failure path of the bringup.
# Needs root plus iproute2, iptables, ethtool, ping, curl, python3, gcc. Every namespace and config
# name carries this run's PID, so it never touches pre-existing state.
set -euo pipefail

cd "$(dirname "$0")/.."
UP=scripts/golden-gre-up.sh
DOWN=scripts/golden-gre-down.sh
CHECK=scripts/golden-gre-check.sh
RELAYSH=scripts/golden-gre-relay.sh

fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "ok: $*"; }

A="gg-a-$$" B="gg-b-$$" C="gg-c-$$"
CA="e2e-a-$$" CB="e2e-b-$$" CC="e2e-c-$$" CA2="e2e-a2-$$" CB2="e2e-b2-$$" CX="e2e-x-$$" CD="e2e-d-$$"
tmp="$(mktemp -d)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  for ns in "$A" "$B" "$C"; do ip netns del "$ns" 2>/dev/null || true; done
  for c in "$CA" "$CB" "$CC" "$CA2" "$CB2" "$CX" "$CD"; do rm -f "/etc/golden-gre/$c.conf"; done
  rm -rf "$tmp"
}
trap cleanup EXIT

gcc -O2 -Wall -o "$tmp/relay" relay/golden-gre-relay.c
export GOLDEN_GRE_RELAY="$tmp/relay"

start_relay() { # namespace instance -> background relay, pid in $RELAY_PID
  ip netns exec "$1" "$RELAYSH" "$2" >"$tmp/relay-$2.log" 2>&1 &
  RELAY_PID=$!
  pids+=("$RELAY_PID")
}

# --- two "servers" on a shared underlay -------------------------------------
ip netns add "$A"
ip netns add "$B"
ip link add veth-a netns "$A" type veth peer name veth-b netns "$B"
ip -n "$A" addr add 192.0.2.1/24 dev veth-a
ip -n "$B" addr add 192.0.2.2/24 dev veth-b
ip -n "$A" addr add 192.0.2.11/24 dev veth-a   # second address pair, for a second tunnel
ip -n "$B" addr add 192.0.2.12/24 dev veth-b
for ns in "$A" "$B"; do ip -n "$ns" link set lo up; done
ip -n "$A" link set veth-a up
ip -n "$B" link set veth-b up

mkdir -p /etc/golden-gre
cat >"/etc/golden-gre/$CA.conf" <<'EOF'
DEV=gre1
LOCAL_PUB=192.0.2.1
REMOTE_PUB=192.0.2.2
TUN_ADDR=10.99.99.1/30
ROUTES="198.18.0.0/24"
NAT_SRC=10.99.99.0/30
GRE_KEY=42
EOF
cat >"/etc/golden-gre/$CB.conf" <<'EOF'
DEV=gre1
LOCAL_PUB=192.0.2.2
REMOTE_PUB=192.0.2.1
TUN_ADDR=10.99.99.2/30
GRE_KEY=42
EOF

# --- up ----------------------------------------------------------------------
ip netns exec "$A" "$UP" "$CA"
ip netns exec "$B" "$UP" "$CB"
start_relay "$A" "$CA"; RELAY_A=$RELAY_PID
start_relay "$B" "$CB"
# A DROP inserted ahead of our rules (Docker/ufw reload) must not survive a re-run.
ip netns exec "$A" iptables -I FORWARD -j DROP
ip netns exec "$A" "$UP" "$CA" >/dev/null   # second run must be harmless

ip netns exec "$A" ping -c 3 -W 2 -q 10.99.99.2 >/dev/null || fail "no ping across the tunnel (first packets must pass: no learning delay)"
ok "ping across the tunnel, from the first packet"

ip -n "$A" -d link show gre1 | grep -q 'encap fou encap-sport 5599 encap-dport 5601' \
  || fail "tunnel is not GRE-in-FOU on the loopback relay ports"
ok "loopback GRE-in-FOU toward the relay"

ip -n "$A" -d link show gre1 | grep -q 'ikey 0.0.0.42 okey 0.0.0.42' || fail "GRE_KEY not applied"
ok "GRE_KEY applied"

ip netns exec "$A" ip fou show | grep -q 'port 5599 ipproto 47 local 127.0.0.1' \
  || fail "FOU listener is not bound to loopback only"
ok "FOU listener on loopback only"

ip -n "$A" route show 198.18.0.0/24 | grep -q 'dev gre1' || fail "ROUTES not installed"
ok "ROUTES installed"

rules="$(ip netns exec "$A" iptables-save)"
for want in \
  '-A FORWARD -i gre1 -j ACCEPT' \
  '-A FORWARD -o gre1 -j ACCEPT' \
  '-A FORWARD -o gre1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' \
  '-A FORWARD -i gre1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' \
  '-A POSTROUTING -s 10.99.99.0/30 ! -o gre1 -j MASQUERADE' \
  "-A INPUT -s 192.0.2.2/32 -p udp -m udp --dport 53 -m comment --comment \"golden-gre:$CA\" -j ACCEPT"; do
  grep -qxF -- "$want" <<<"$rules" || fail "missing rule: $want"
  [ "$(grep -cxF -- "$want" <<<"$rules")" = 1 ] || fail "duplicated after re-run: $want"
done
grep -qE -- '-A INPUT .*--dport 53 .*-j DROP' <<<"$rules" && fail "a DROP on the DNS port would break a local resolver"
ok "FORWARD accept, MSS clamp, MASQUERADE and the peer-only INPUT accept present exactly once; no DROP"

top="$(ip netns exec "$A" iptables -S FORWARD | sed -n '2,3p')"
for want in '-A FORWARD -i gre1 -j ACCEPT' '-A FORWARD -o gre1 -j ACCEPT'; do
  grep -qxF -- "$want" <<<"$top" || fail "FORWARD accepts are not ahead of the DROP: $top"
done
ip netns exec "$A" iptables -D FORWARD -j DROP
ok "re-run moves FORWARD accepts back above a DROP"

# --- data, not just ping -------------------------------------------------------
head -c 20000000 /dev/urandom >"$tmp/blob"
(cd "$tmp" && ip netns exec "$B" python3 -m http.server 8000 --bind 10.99.99.2 >/dev/null 2>&1) &
pids+=("$!")
sleep 1
got="$(ip netns exec "$A" curl -s --max-time 60 -o "$tmp/got" -w '%{size_download}' http://10.99.99.2:8000/blob)"
[ "$got" = 20000000 ] || fail "20 MB transfer through the tunnel returned $got bytes"
cmp -s "$tmp/blob" "$tmp/got" || fail "transferred data differs"
ok "20 MB transferred through the tunnel, bit for bit"

# --- a failing re-run on a live tunnel must not tear it down -------------------
# systemd still shows such a tunnel active, so nothing would bring it back.
echo 'ROUTES="10.50.0.0/33"' >>"/etc/golden-gre/$CA.conf"
ip netns exec "$A" "$UP" "$CA" >/dev/null 2>&1 && fail "up succeeded with an invalid ROUTES entry"
sed -i '$d' "/etc/golden-gre/$CA.conf"
ip netns exec "$A" ping -c 3 -W 2 -q 10.99.99.2 >/dev/null || fail "a failed re-run tore down a live tunnel"
ok "a failing re-run leaves a live tunnel up"

# --- health check ------------------------------------------------------------
ip netns exec "$A" "$CHECK" "$CA" >/dev/null || fail "check failed on a healthy tunnel"
ip netns exec "$B" "$CHECK" "$CB" >/dev/null || fail "check failed from the .2 end (peer derivation)"
ok "check passes on a healthy tunnel"

sed -i 's/^GRE_KEY=42$/GRE_KEY=43/' "/etc/golden-gre/$CB.conf"
ip netns exec "$B" "$UP" "$CB" >/dev/null
ip netns exec "$A" "$CHECK" "$CA" >/dev/null 2>&1 && fail "check passed although the GRE keys differ"
ok "mismatched GRE_KEY blocks traffic and check reports it"
sed -i 's/^GRE_KEY=43$/GRE_KEY=42/' "/etc/golden-gre/$CB.conf"
ip netns exec "$B" "$UP" "$CB" >/dev/null

# --- a second tunnel on the same two hosts -------------------------------------
# Own addresses (the relay binds one), GRE key, FOU port and relay port.
cat >"/etc/golden-gre/$CA2.conf" <<'EOF'
DEV=gre2
LOCAL_PUB=192.0.2.11
REMOTE_PUB=192.0.2.12
TUN_ADDR=10.99.97.1/30
GRE_KEY=44
FOU_PORT=5600
RELAY_PORT=5602
EOF
cat >"/etc/golden-gre/$CB2.conf" <<'EOF'
DEV=gre2
LOCAL_PUB=192.0.2.12
REMOTE_PUB=192.0.2.11
TUN_ADDR=10.99.97.2/30
GRE_KEY=44
FOU_PORT=5600
RELAY_PORT=5602
EOF
# A tunnel that reuses the first tunnel's FOU port must be refused without touching the first one.
cat >"/etc/golden-gre/$CD.conf" <<'EOF'
DEV=gre3
LOCAL_PUB=192.0.2.11
REMOTE_PUB=192.0.2.12
TUN_ADDR=10.99.95.1/30
GRE_KEY=45
RELAY_PORT=5603
EOF
out="$(ip netns exec "$A" "$UP" "$CD" 2>&1)" && fail "up accepted a FOU port that another tunnel holds"
grep -q 'already in use' <<<"$out" || fail "the shared FOU port is not explained: $out"
ip -n "$A" link show gre3 >/dev/null 2>&1 && fail "refused up left a device behind"
ip netns exec "$A" ping -c 3 -W 2 -q 10.99.99.2 >/dev/null || fail "refusing a second tunnel broke the first"
ip netns exec "$A" ip fou show | grep -q 'port 5599' || fail "refusing a second tunnel removed the first tunnel's FOU listener"
ok "a tunnel sharing another tunnel's FOU port is refused and the first keeps running"

ip netns exec "$A" scripts/preflight.sh "$CA2" >/dev/null || fail "preflight rejected a valid config"
ok "preflight accepts a valid config"
ip netns exec "$A" "$UP" "$CA2"
ip netns exec "$B" "$UP" "$CB2"
start_relay "$A" "$CA2"; RELAY_A2=$RELAY_PID
start_relay "$B" "$CB2"; RELAY_B2=$RELAY_PID
ip netns exec "$A" ping -c 3 -W 2 -q 10.99.97.2 >/dev/null || fail "no ping across the second tunnel"
ip netns exec "$A" ping -c 3 -W 2 -q 10.99.99.2 >/dev/null || fail "the first tunnel stopped working"
ok "two tunnels between the same hosts both carry traffic"
ip netns exec "$A" scripts/preflight.sh "$CA2" >/dev/null 2>&1 && fail "preflight accepted a DNS port that the running relay holds"
ok "preflight reports the DNS port in use"

# --- down --------------------------------------------------------------------
kill "$RELAY_A2" "$RELAY_B2" 2>/dev/null || true
ip netns exec "$A" "$DOWN" "$CA2" >/dev/null
ip netns exec "$B" "$DOWN" "$CB2" >/dev/null
ip netns exec "$A" ping -c 3 -W 2 -q 10.99.99.2 >/dev/null || fail "downing the second tunnel broke the first"
ip -n "$A" link show gre2 >/dev/null 2>&1 && fail "gre2 still exists after down"
ip netns exec "$A" ip fou show | grep -q 'port 5600' && fail "second tunnel's FOU listener left behind"
ip netns exec "$A" iptables-save | grep -q "golden-gre:$CA2" && fail "second tunnel's INPUT rule left behind"
ok "downing one tunnel leaves the other running and removes only its own state"

kill "$RELAY_A" 2>/dev/null || true
ip netns exec "$A" "$DOWN" "$CA"
ip netns exec "$A" "$DOWN" "$CA" >/dev/null   # second run must be harmless
ip -n "$A" link show gre1 >/dev/null 2>&1 && fail "gre1 still exists after down"
ip netns exec "$A" ip fou show | grep -q 'port 5599' && fail "FOU listener left behind"
ip netns exec "$A" iptables-save | grep -qE 'gre1|golden-gre:' && fail "iptables rules left behind"
ok "down removed device, FOU listener and rules"

# --- the icmp facade -----------------------------------------------------------
sed -i 's/^TUN_ADDR=10.99.97.1\/30$/TUN_ADDR=10.99.97.1\/30\nFACADE=icmp/' "/etc/golden-gre/$CA2.conf"
sed -i 's/^TUN_ADDR=10.99.97.2\/30$/TUN_ADDR=10.99.97.2\/30\nFACADE=icmp/' "/etc/golden-gre/$CB2.conf"
ip netns exec "$A" "$UP" "$CA2" >/dev/null
ip netns exec "$B" "$UP" "$CB2" >/dev/null
start_relay "$A" "$CA2"
start_relay "$B" "$CB2"
ip netns exec "$A" ping -c 3 -W 2 -q 10.99.97.2 >/dev/null || fail "no ping across a tunnel with the icmp facade"
ip netns exec "$A" iptables-save | grep -qF -- "-A INPUT -s 192.0.2.12/32 -p icmp -m comment --comment \"golden-gre:$CA2\" -j ACCEPT" \
  || fail "icmp facade has no peer-only icmp INPUT accept"
ok "icmp facade carries traffic and opens icmp from the peer only"
kill "${pids[@]: -2}" 2>/dev/null || true
ip netns exec "$A" "$DOWN" "$CA2" >/dev/null
ip netns exec "$B" "$DOWN" "$CB2" >/dev/null
ip netns exec "$A" iptables-save | grep -q "golden-gre:$CA2" && fail "icmp INPUT rule left behind"
ok "down removes the icmp rule"

# --- a bringup that fails partway must roll back everything it created --------
# MTU is applied after the FOU listener, INPUT rule, device and address exist.
echo 'MTU=bogus' >>"/etc/golden-gre/$CA.conf"
ip netns exec "$A" "$UP" "$CA" >/dev/null 2>&1 && fail "up succeeded with an invalid MTU"
ip -n "$A" link show gre1 >/dev/null 2>&1 && fail "failed up left gre1 behind"
ip netns exec "$A" ip fou show | grep -q 'port 5599' && fail "failed up left the FOU listener behind"
ip netns exec "$A" iptables-save | grep -qE 'gre1|golden-gre:' && fail "failed up left iptables rules behind"
ok "failed bringup rolls back device, FOU listener and rules"

# --- a bringup stopped mid-run (systemctl stop during start) must roll back too -
# An ethtool shim holds up at the GSO step, after listener, rules and device
# exist. SIGTERM goes to the whole process group, as systemd sends it to the cgroup.
sed -i '/^MTU=bogus$/d' "/etc/golden-gre/$CA.conf"
shim="$(mktemp -d)"
printf '#!/bin/sh\nexec sleep 30\n' >"$shim/ethtool"
chmod +x "$shim/ethtool"
ip netns exec "$A" env PATH="$shim:$PATH" setsid "$UP" "$CA" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 50); do ip -n "$A" link show gre1 >/dev/null 2>&1 && break; sleep 0.1; done
ip -n "$A" link show gre1 >/dev/null 2>&1 || fail "up never reached the device step"
kill -TERM -- "-$pid"
rc=0; wait "$pid" || rc=$?
rm -rf "$shim"
[ "$rc" -ne 0 ] || fail "up exited 0 after SIGTERM"
ip -n "$A" link show gre1 >/dev/null 2>&1 && fail "stopped up left gre1 behind"
ip netns exec "$A" ip fou show | grep -q 'port 5599' && fail "stopped up left the FOU listener behind"
ip netns exec "$A" iptables-save | grep -qE 'gre1|golden-gre:' && fail "stopped up left iptables rules behind"
ok "bringup stopped by SIGTERM rolls back"

# --- early boot: the local address or the route is not there yet -----------------
ip netns add "$C"
ip -n "$C" link set lo up
cat >"/etc/golden-gre/$CC.conf" <<'EOF'
DEV=gre1
LOCAL_PUB=192.0.2.9
REMOTE_PUB=198.51.100.9
TUN_ADDR=10.99.98.1/30
EOF
ip netns exec "$C" "$UP" "$CC" 2>/dev/null && fail "up succeeded although LOCAL_PUB is not on this host"
ip -n "$C" link show gre1 >/dev/null 2>&1 && fail "failed up left gre1 behind"
ok "LOCAL_PUB not configured yet: up fails before creating anything"

ip -n "$C" link add dummy0 type dummy
ip -n "$C" addr add 192.0.2.9/32 dev dummy0
ip -n "$C" link set dummy0 up
out="$(ip netns exec "$C" "$UP" "$CC" 2>&1)" && fail "up succeeded with no route to the peer"
grep -q 'no route' <<<"$out" || fail "missing route is not explained: $out"
ip -n "$C" link show gre1 >/dev/null 2>&1 && fail "failed up left gre1 behind"
ok "no route to the peer: up fails before creating anything"

# --- IPv4 only -----------------------------------------------------------------
cat >"/etc/golden-gre/$CX.conf" <<'EOF'
DEV=gre1
LOCAL_PUB=2001:db8::1
REMOTE_PUB=2001:db8::2
TUN_ADDR=10.99.96.1/30
EOF
out="$(ip netns exec "$A" "$UP" "$CX" 2>&1)" && fail "up accepted IPv6 endpoints"
grep -q 'IPv4' <<<"$out" || fail "IPv6 endpoints are not explained: $out"
ok "IPv6 endpoints are rejected with an explanation"

echo "e2e: PASS"
