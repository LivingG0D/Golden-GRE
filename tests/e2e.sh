#!/usr/bin/env bash
# End-to-end test: two network namespaces joined by a veth pair stand in for two
# servers. Brings a real tunnel up with scripts/golden-gre-up.sh, pings across it,
# checks the firewall state, then tears it down and checks nothing is left behind.
# Needs root plus iproute2, iptables, ethtool, ping. Touches only its own
# namespaces and its own /etc/golden-gre/e2e-*.conf files.
set -euo pipefail

cd "$(dirname "$0")/.."
UP=scripts/golden-gre-up.sh
DOWN=scripts/golden-gre-down.sh

fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "ok: $*"; }

cleanup() {
  ip netns del gg-a 2>/dev/null || true
  ip netns del gg-b 2>/dev/null || true
  ip netns del gg-c 2>/dev/null || true
  rm -f /etc/golden-gre/e2e-a.conf /etc/golden-gre/e2e-b.conf /etc/golden-gre/e2e-c.conf
}
trap cleanup EXIT
cleanup

# --- two "servers" on a shared underlay -------------------------------------
ip netns add gg-a
ip netns add gg-b
ip link add veth-a netns gg-a type veth peer name veth-b netns gg-b
ip -n gg-a addr add 192.0.2.1/24 dev veth-a
ip -n gg-b addr add 192.0.2.2/24 dev veth-b
for ns in gg-a gg-b; do ip -n "$ns" link set lo up; done
ip -n gg-a link set veth-a up
ip -n gg-b link set veth-b up

mkdir -p /etc/golden-gre
cat >/etc/golden-gre/e2e-a.conf <<'EOF'
DEV=gre1
LOCAL_PUB=192.0.2.1
REMOTE_PUB=192.0.2.2
TUN_ADDR=10.99.99.1/30
FOU_PORT=5555
ROUTES="198.18.0.0/24"
NAT_SRC=10.99.99.0/30
EOF
cat >/etc/golden-gre/e2e-b.conf <<'EOF'
DEV=gre1
LOCAL_PUB=192.0.2.2
REMOTE_PUB=192.0.2.1
TUN_ADDR=10.99.99.2/30
FOU_PORT=5555
EOF

# --- up ----------------------------------------------------------------------
ip netns exec gg-a "$UP" e2e-a
ip netns exec gg-b "$UP" e2e-b
ip netns exec gg-a "$UP" e2e-a >/dev/null   # second run must be harmless

ip netns exec gg-a ping -c 3 -W 2 -q 10.99.99.2 >/dev/null || fail "no ping across the tunnel"
ok "ping across the tunnel"

ip -n gg-a -d link show gre1 | grep -q 'encap-sport auto' \
  || fail "FOU source port is pinned; expected encap-sport auto"
ok "encap-sport auto"

ip -n gg-a route show 198.18.0.0/24 | grep -q 'dev gre1' || fail "ROUTES not installed"
ok "ROUTES installed"

rules="$(ip netns exec gg-a iptables-save)"
for want in \
  '-A FORWARD -i gre1 -j ACCEPT' \
  '-A FORWARD -o gre1 -j ACCEPT' \
  '-A FORWARD -o gre1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' \
  '-A FORWARD -i gre1 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' \
  '-A POSTROUTING -s 10.99.99.0/30 ! -o gre1 -j MASQUERADE'; do
  grep -qxF -- "$want" <<<"$rules" || fail "missing rule: $want"
  [ "$(grep -cxF -- "$want" <<<"$rules")" = 1 ] || fail "duplicated after re-run: $want"
done
ok "FORWARD accept, MSS clamp and MASQUERADE present exactly once"

# --- down --------------------------------------------------------------------
ip netns exec gg-a "$DOWN" e2e-a
ip netns exec gg-a "$DOWN" e2e-a >/dev/null   # second run must be harmless

ip -n gg-a link show gre1 >/dev/null 2>&1 && fail "gre1 still exists after down"
ip netns exec gg-a ip fou show | grep -q 'port 5555' && fail "FOU listener left behind"
ip netns exec gg-a iptables-save | grep -q gre1 && fail "iptables rules left behind"
ok "down removed device, FOU listener and rules"

# --- boot race: no route to the peer yet must not abort bringup --------------
ip netns add gg-c
ip -n gg-c link set lo up
cat >/etc/golden-gre/e2e-c.conf <<'EOF'
DEV=gre1
LOCAL_PUB=192.0.2.9
REMOTE_PUB=198.51.100.9
TUN_ADDR=10.99.98.1/30
FOU_PORT=5556
EOF
ip netns exec gg-c "$UP" e2e-c >/dev/null || fail "up aborted when the peer has no route yet"
ok "up survives a missing route to the peer"

echo "e2e: PASS"
