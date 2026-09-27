#!/usr/bin/env bash
# End-to-end test: two network namespaces joined by a veth pair stand in for two
# servers. Brings a real tunnel up with scripts/golden-gre-up.sh, pings across it,
# checks the firewall state and the health check, then tears it down and checks
# nothing is left behind. Needs root plus iproute2, iptables, ethtool, ping, python3. Every namespace and config
# name carries this run's PID, so it never touches pre-existing state.
set -euo pipefail

cd "$(dirname "$0")/.."
UP=scripts/golden-gre-up.sh
DOWN=scripts/golden-gre-down.sh
CHECK=scripts/golden-gre-check.sh

fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "ok: $*"; }

A="gg-a-$$" B="gg-b-$$" C="gg-c-$$"
CA="e2e-a-$$" CB="e2e-b-$$" CC="e2e-c-$$"
cleanup() {
  for ns in "$A" "$B" "$C"; do ip netns del "$ns" 2>/dev/null || true; done
  rm -f "/etc/golden-gre/$CA.conf" "/etc/golden-gre/$CB.conf" "/etc/golden-gre/$CC.conf"
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

echo "e2e: PASS"
