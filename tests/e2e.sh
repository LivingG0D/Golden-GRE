#!/usr/bin/env bash
# End-to-end test: two network namespaces joined by a veth pair stand in for two
# servers. Brings a real tunnel up with scripts/golden-gre-up.sh, pings across it,
# checks the firewall state and the health check, then tears it down and checks
# nothing is left behind. Needs root plus iproute2, iptables, ethtool, ping, python3. Every namespace and config
# name carries this run's PID, so it never touches pre-existing state. The last part
# repeats the exercise with an IPv6 underlay (plain GRE, no FOU).
set -euo pipefail

cd "$(dirname "$0")/.."
UP=scripts/golden-gre-up.sh
DOWN=scripts/golden-gre-down.sh
CHECK=scripts/golden-gre-check.sh

fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "ok: $*"; }

A="gg-a-$$" B="gg-b-$$" C="gg-c-$$"
CA="e2e-a-$$" CB="e2e-b-$$" CC="e2e-c-$$"
# IPv6-underlay configs (second tunnel to the same peer, mixed families, no route)
CA6="e2e-a6-$$" CB6="e2e-b6-$$" CD6="e2e-d6-$$" CE6="e2e-e6-$$" CC6="e2e-c6-$$"
cleanup() {
  for ns in "$A" "$B" "$C"; do ip netns del "$ns" 2>/dev/null || true; done
  rm -f "/etc/golden-gre/$CA.conf" "/etc/golden-gre/$CB.conf" "/etc/golden-gre/$CC.conf"
  for c in "$CA6" "$CB6" "$CD6" "$CE6" "$CC6"; do rm -f "/etc/golden-gre/$c.conf"; done
}
trap cleanup EXIT

# --- two "servers" on a shared underlay -------------------------------------
ip netns add "$A"
ip netns add "$B"
ip link add veth-a netns "$A" type veth peer name veth-b netns "$B"
ip -n "$A" addr add 192.0.2.1/24 dev veth-a
ip -n "$B" addr add 192.0.2.2/24 dev veth-b
for ns in "$A" "$B"; do ip -n "$ns" link set lo up; done
ip -n "$A" link set veth-a up
ip -n "$B" link set veth-b up

mkdir -p /etc/golden-gre
cat >"/etc/golden-gre/$CA.conf" <<'EOF'
DEV=gre1
LOCAL_PUB=192.0.2.1
REMOTE_PUB=192.0.2.2
TUN_ADDR=10.99.99.1/30
FOU_PORT=5555
ROUTES="198.18.0.0/24"
NAT_SRC=10.99.99.0/30
GRE_KEY=42
EOF
cat >"/etc/golden-gre/$CB.conf" <<'EOF'
DEV=gre1
LOCAL_PUB=192.0.2.2
REMOTE_PUB=192.0.2.1
TUN_ADDR=10.99.99.2/30
FOU_PORT=5555
GRE_KEY=42
EOF

# --- up ----------------------------------------------------------------------
ip netns exec "$A" "$UP" "$CA"
ip netns exec "$B" "$UP" "$CB"
# A DROP inserted ahead of our rules (Docker/ufw reload) must not survive a re-run.
ip netns exec "$A" iptables -I FORWARD -j DROP
ip netns exec "$A" "$UP" "$CA" >/dev/null   # second run must be harmless

ip netns exec "$A" ping -c 3 -W 2 -q 10.99.99.2 >/dev/null || fail "no ping across the tunnel"
ok "ping across the tunnel"

ip -n "$A" -d link show gre1 | grep -q 'encap-sport auto' \
  || fail "FOU source port is pinned; expected encap-sport auto"
ok "encap-sport auto"

ip -n "$A" -d link show gre1 | grep -q 'ikey 0.0.0.42 okey 0.0.0.42' || fail "GRE_KEY not applied"
ok "GRE_KEY applied"

ip -n "$A" route show 198.18.0.0/24 | grep -q 'dev gre1' || fail "ROUTES not installed"
ok "ROUTES installed"

rules="$(ip netns exec "$A" iptables-save)"
for want in \
  '-A FORWARD -i gre1 -j ACCEPT' \
  '-A FORWARD -o gre1 -j ACCEPT' \
  '-A FORWARD -o gre1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' \
  '-A FORWARD -i gre1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' \
  '-A POSTROUTING -s 10.99.99.0/30 ! -o gre1 -j MASQUERADE'   '-A INPUT -s 192.0.2.2/32 -p udp -m udp --dport 5555 -j ACCEPT'   '-A INPUT ! -s 192.0.2.2/32 -p udp -m udp --dport 5555 -j DROP'; do
  grep -qxF -- "$want" <<<"$rules" || fail "missing rule: $want"
  [ "$(grep -cxF -- "$want" <<<"$rules")" = 1 ] || fail "duplicated after re-run: $want"
done
ok "FORWARD accept, MSS clamp, MASQUERADE and FOU INPUT rules present exactly once"

top="$(ip netns exec "$A" iptables -S FORWARD | sed -n '2,3p')"
for want in '-A FORWARD -i gre1 -j ACCEPT' '-A FORWARD -o gre1 -j ACCEPT'; do
  grep -qxF -- "$want" <<<"$top" || fail "FORWARD accepts are not ahead of the DROP: $top"
done
ip netns exec "$A" iptables -D FORWARD -j DROP
ok "re-run moves FORWARD accepts back above a DROP"

# --- a failing re-run on a live tunnel must not tear it down -------------------
# systemd still shows such a tunnel active, so nothing would bring it back.
echo 'ROUTES="10.50.0.0/33"' >>"/etc/golden-gre/$CA.conf"
ip netns exec "$A" "$UP" "$CA" >/dev/null 2>&1 && fail "up succeeded with an invalid ROUTES entry"
sed -i '$d' "/etc/golden-gre/$CA.conf"
ip netns exec "$A" ping -c 3 -W 2 -q 10.99.99.2 >/dev/null || fail "a failed re-run tore down a live tunnel"
ok "a failing re-run leaves a live tunnel up"

# --- FOU port only takes packets from the peer --------------------------------
ip -n "$B" addr add 192.0.2.3/24 dev veth-b
ip netns exec "$B" python3 -c 'import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("192.0.2.3", 0))
s.sendto(b"x", ("192.0.2.1", 5555))'
drops="$(ip netns exec "$A" iptables -L INPUT -v -x -n | awk '$3 == "DROP" && /dpt:5555/ {print $1}')"
[ "${drops:-0}" -ge 1 ] || fail "UDP to the FOU port from a non-peer address was not dropped"
ok "FOU port drops packets from other sources"

# --- health check ------------------------------------------------------------
ip netns exec "$A" "$CHECK" "$CA" >/dev/null || fail "check failed on a healthy tunnel"
ip netns exec "$B" "$CHECK" "$CB" >/dev/null || fail "check failed from the .2 end (peer derivation)"
ok "check passes on a healthy tunnel"

sed -i 's/^GRE_KEY=42$/GRE_KEY=43/' "/etc/golden-gre/$CB.conf"
ip netns exec "$B" "$UP" "$CB" >/dev/null
ip netns exec "$A" "$CHECK" "$CA" >/dev/null 2>&1 && fail "check passed although the GRE keys differ"
ok "mismatched GRE_KEY blocks traffic and check reports it"

# --- down --------------------------------------------------------------------
ip netns exec "$A" "$DOWN" "$CA"
ip netns exec "$A" "$DOWN" "$CA" >/dev/null   # second run must be harmless

ip -n "$A" link show gre1 >/dev/null 2>&1 && fail "gre1 still exists after down"
ip netns exec "$A" ip fou show | grep -q 'port 5555' && fail "FOU listener left behind"
ip netns exec "$A" iptables-save | grep -qE 'gre1|dport 5555' && fail "iptables rules left behind"
ok "down removed device, FOU listener and rules"

# --- a bringup that fails partway must roll back everything it created --------
# MTU is applied after the FOU listener, INPUT rules, device and address exist.
echo 'MTU=bogus' >>"/etc/golden-gre/$CA.conf"
ip netns exec "$A" "$UP" "$CA" >/dev/null 2>&1 && fail "up succeeded with an invalid MTU"
ip -n "$A" link show gre1 >/dev/null 2>&1 && fail "failed up left gre1 behind"
ip netns exec "$A" ip fou show | grep -q 'port 5555' && fail "failed up left the FOU listener behind"
ip netns exec "$A" iptables-save | grep -qE 'gre1|dport 5555' && fail "failed up left iptables rules behind"
ok "failed bringup rolls back device, FOU listener and rules"

# --- a bringup stopped mid-run (systemctl stop during start) must roll back too -
# An ethtool shim holds up at the GRO step, after listener, rules and device
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
ip netns exec "$A" ip fou show | grep -q 'port 5555' && fail "stopped up left the FOU listener behind"
ip netns exec "$A" iptables-save | grep -qE 'gre1|dport 5555' && fail "stopped up left iptables rules behind"
ok "bringup stopped by SIGTERM rolls back"

# --- boot race: no route to the peer yet must fail cleanly (systemd retries) --
ip netns add "$C"
ip -n "$C" link set lo up
cat >"/etc/golden-gre/$CC.conf" <<'EOF'
DEV=gre1
LOCAL_PUB=192.0.2.9
REMOTE_PUB=198.51.100.9
TUN_ADDR=10.99.98.1/30
FOU_PORT=5556
EOF
ip netns exec "$C" "$UP" "$CC" 2>/dev/null && fail "up succeeded with no route to the peer"
ip -n "$C" link show gre1 >/dev/null 2>&1 && fail "failed up left gre1 behind"
ok "no route to the peer: up fails before creating anything"

# --- IPv6 underlay: plain GRE over IPv6 (ip6gre), no FOU --------------------------
# Same two servers, now also reachable over IPv6. The overlay stays IPv4.
ip -n "$A" addr add 2001:db8:6::1/64 dev veth-a nodad
ip -n "$B" addr add 2001:db8:6::2/64 dev veth-b nodad

cat >"/etc/golden-gre/$CA6.conf" <<'EOF'
DEV=gre6
LOCAL_PUB=2001:db8:6::1
REMOTE_PUB=2001:db8:6::2
TUN_ADDR=10.99.96.1/30
GRE_KEY=7
EOF
cat >"/etc/golden-gre/$CB6.conf" <<'EOF'
DEV=gre6
LOCAL_PUB=2001:db8:6::2
REMOTE_PUB=2001:db8:6::1
TUN_ADDR=10.99.96.2/30
GRE_KEY=7
EOF

ip netns exec "$A" "$UP" "$CA6"
ip netns exec "$B" "$UP" "$CB6"
ip netns exec "$A" "$UP" "$CA6" >/dev/null   # second run must be harmless
ip netns exec "$A" ping -c 3 -W 2 -q 10.99.96.2 >/dev/null || fail "no ping across the IPv6-underlay tunnel"
ok "ping across a tunnel whose underlay is IPv6"

ip -n "$A" -d link show gre6 | grep -q 'ip6gre' || fail "IPv6 underlay did not create an ip6gre device"
ip -n "$A" -d link show gre6 | grep -q 'ikey 0.0.0.7 okey 0.0.0.7' || fail "GRE_KEY not applied over IPv6"
ok "ip6gre device with GRE_KEY"

ip netns exec "$A" scripts/preflight.sh "$CA6" >/dev/null || fail "preflight rejected a valid IPv6 config (it needs no FOU_PORT)"
ok "preflight accepts an IPv6 config without FOU_PORT"

ip netns exec "$A" ip fou show | grep -q 'port' && fail "IPv6 underlay opened a FOU listener"
ip netns exec "$A" iptables-save | grep -q 'dport' && fail "IPv6 underlay added a UDP INPUT rule"
ok "no FOU listener and no UDP rules for an IPv6 underlay"

# Plain GRE has no port to pin, so the INPUT rule is per protocol and peer. It carries
# the instance name, so tunnels sharing a peer each own (and later remove) their rule.
in6() { printf -- '-A INPUT -s 2001:db8:6::2/128 -p (gre|47) -m comment --comment "golden-gre:%s" -j ACCEPT$' "$1"; }
rules6="$(ip netns exec "$A" ip6tables-save)"
[ "$(grep -cE -- "$(in6 "$CA6")" <<<"$rules6")" = 1 ] || fail "IPv6 INPUT accept is not present exactly once"
rules4="$(ip netns exec "$A" iptables-save)"
for want in '-A FORWARD -i gre6 -j ACCEPT' '-A FORWARD -o gre6 -j ACCEPT'; do
  [ "$(grep -cxF -- "$want" <<<"$rules4")" = 1 ] || fail "missing or duplicated rule: $want"
done
ok "INPUT accept and FORWARD accepts present exactly once"

cat >"/etc/golden-gre/$CD6.conf" <<'EOF'
DEV=gre7
LOCAL_PUB=2001:db8:6::1
REMOTE_PUB=2001:db8:6::2
TUN_ADDR=10.99.95.1/30
GRE_KEY=8
EOF
ip netns exec "$A" "$UP" "$CD6" >/dev/null
ip netns exec "$A" "$DOWN" "$CD6" >/dev/null
rules6="$(ip netns exec "$A" ip6tables-save)"
[ "$(grep -cE -- "$(in6 "$CA6")" <<<"$rules6")" = 1 ] || fail "downing a second tunnel to the same peer removed this tunnel's INPUT rule"
grep -q "golden-gre:$CD6" <<<"$rules6" && fail "down left the second tunnel's INPUT rule"
ok "tunnels to the same peer keep their own INPUT rules"

ip netns exec "$A" "$CHECK" "$CA6" >/dev/null || fail "check failed on a healthy IPv6-underlay tunnel"
sed -i 's/^GRE_KEY=7$/GRE_KEY=9/' "/etc/golden-gre/$CB6.conf"
ip netns exec "$B" "$UP" "$CB6" >/dev/null
ip netns exec "$A" "$CHECK" "$CA6" >/dev/null 2>&1 && fail "check passed although the GRE keys differ over IPv6"
ok "mismatched GRE_KEY blocks traffic over IPv6 too"

cat >"/etc/golden-gre/$CE6.conf" <<'EOF'
DEV=gre8
LOCAL_PUB=192.0.2.1
REMOTE_PUB=2001:db8:6::2
TUN_ADDR=10.99.94.1/30
FOU_PORT=5557
EOF
out="$(ip netns exec "$A" "$UP" "$CE6" 2>&1)" && fail "up accepted mixed IPv4/IPv6 endpoints"
grep -qi 'same address family' <<<"$out" || fail "mixed address families are not explained: $out"
ip -n "$A" link show gre8 >/dev/null 2>&1 && fail "mixed-family up left a device behind"
ok "mixed address families are rejected before anything is created"

ip netns exec "$A" "$DOWN" "$CA6"
ip netns exec "$A" "$DOWN" "$CA6" >/dev/null   # second run must be harmless
ip -n "$A" link show gre6 >/dev/null 2>&1 && fail "gre6 still exists after down"
ip netns exec "$A" ip6tables-save | grep -q 'golden-gre:' && fail "IPv6 INPUT rule left behind"
ip netns exec "$A" iptables-save | grep -q 'gre6' && fail "iptables rules left behind"
ok "down removed the IPv6 tunnel and its rules"

echo 'MTU=bogus' >>"/etc/golden-gre/$CA6.conf"
ip netns exec "$A" "$UP" "$CA6" >/dev/null 2>&1 && fail "up succeeded with an invalid MTU over IPv6"
ip -n "$A" link show gre6 >/dev/null 2>&1 && fail "failed IPv6 up left gre6 behind"
ip netns exec "$A" ip6tables-save | grep -q 'golden-gre:' && fail "failed IPv6 up left its INPUT rule behind"
ip netns exec "$A" iptables-save | grep -q 'gre6' && fail "failed IPv6 up left iptables rules behind"
ok "failed IPv6 bringup rolls back device and rules"

cat >"/etc/golden-gre/$CC6.conf" <<'EOF'
DEV=gre6
LOCAL_PUB=2001:db8:6::9
REMOTE_PUB=2001:db8:ffff::9
TUN_ADDR=10.99.93.1/30
EOF
ip netns exec "$C" "$UP" "$CC6" 2>/dev/null && fail "IPv6 up succeeded with no route to the peer"
ip -n "$C" link show gre6 >/dev/null 2>&1 && fail "failed IPv6 up left gre6 behind"
ok "IPv6: no route to the peer fails before creating anything"

echo "e2e: PASS"
