#!/usr/bin/env bash
# Golden GRE — bring up one GRE tunnel from /etc/golden-gre/<instance>.conf:
# GRE-over-FOU (UDP) on an IPv4 underlay, plain GRE on an IPv6 one.
# Usage: golden-gre-up.sh <instance>
set -euo pipefail

NAME="${1:?usage: golden-gre-up.sh <instance>}"
CONF="/etc/golden-gre/${NAME}.conf"
[ -r "$CONF" ] || { echo "golden-gre: missing config $CONF" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"

: "${DEV:?DEV not set in $CONF}"
: "${LOCAL_PUB:?LOCAL_PUB not set in $CONF}"
: "${REMOTE_PUB:?REMOTE_PUB not set in $CONF}"
: "${TUN_ADDR:?TUN_ADDR not set in $CONF}"
MTU="${MTU:-1400}"

# The endpoints pick the underlay: IPv4 is GRE-over-FOU and needs FOU_PORT; IPv6
# is plain GRE (ip6gre), which has no UDP wrapper and so no port. The overlay
# (TUN_ADDR) is IPv4 either way.
L6=0 R6=0
case "${LOCAL_PUB}" in *:*) L6=1 ;; esac
case "${REMOTE_PUB}" in *:*) R6=1 ;; esac
[ "${L6}" = "${R6}" ] || { echo "golden-gre: LOCAL_PUB and REMOTE_PUB must be the same address family ($CONF)" >&2; exit 1; }
V6="${R6}"
[ "${V6}" = 1 ] || : "${FOU_PORT:?FOU_PORT not set in $CONF}"

# The tunnel cannot pass traffic without an underlay route to the peer, and the
# GRO fix below needs its NIC. At early boot the route may not exist yet: fail
# before touching anything and let systemd's Restart=on-failure retry.
UL="$(ip route get "${REMOTE_PUB}" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')" || true
[ -n "${UL}" ] || { echo "golden-gre: no route to ${REMOTE_PUB} yet" >&2; exit 1; }

# On a fresh bringup, roll back on any failure: systemd never runs ExecStop for a
# start that failed, so a half-built tunnel (listener, rules, device) would stay
# behind. Only when the device does not exist yet: a failing re-run by hand on a
# live tunnel must not tear it down while systemd still reports it active.
rollback() {
  local rc=$?
  [ "$rc" -eq 0 ] && return
  echo "golden-gre: ${NAME} bringup failed (exit ${rc}), rolling back" >&2
  "$(dirname "$0")/golden-gre-down.sh" "${NAME}" >/dev/null 2>&1
}
if ! ip link show "${DEV}" >/dev/null 2>&1; then
  trap rollback EXIT
  # A stop during bringup (SIGTERM from systemd) must roll back too, but the EXIT
  # trap would see $? of the last finished command, usually 0. Exit non-zero.
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
fi

if [ "${V6}" = 1 ]; then
  # Plain GRE has no port to open or pin. Accept protocol 47 from the peer so it
  # works on hosts whose INPUT policy is DROP (ufw). No DROP rule for other sources:
  # the kernel only delivers GRE that matches this tunnel's endpoints and key, and a
  # protocol-wide DROP would cut every other tunnel on the host. The rule carries the
  # instance name, so tunnels sharing a peer each own (and later remove) their own.
  ip6tables -D INPUT -p 47 -s "${REMOTE_PUB}" -m comment --comment "golden-gre:${NAME}" -j ACCEPT 2>/dev/null || true
  ip6tables -I INPUT -p 47 -s "${REMOTE_PUB}" -m comment --comment "golden-gre:${NAME}" -j ACCEPT
else
  # fou has no module alias, so `ip fou add` cannot autoload it. ip_gre does
  # autoload (rtnl-link-gre) at `ip link add type gre`.
  modprobe fou

  # FOU decapsulation listener (idempotent)
  ip fou show 2>/dev/null | grep -q "port ${FOU_PORT} " \
    || ip fou add port "${FOU_PORT}" ipproto 47

  # The FOU port takes packets from the peer only. Deleted and re-inserted so both
  # rules sit at the top of INPUT: the ACCEPT opens the port on hosts whose INPUT
  # policy is DROP (ufw); the DROP shuts out every other source.
  for RULE in "-s ${REMOTE_PUB} -j ACCEPT" "! -s ${REMOTE_PUB} -j DROP"; do
    read -ra r <<<"${RULE}"
    iptables -D INPUT -p udp --dport "${FOU_PORT}" "${r[@]}" 2>/dev/null || true
    iptables -I INPUT -p udp --dport "${FOU_PORT}" "${r[@]}"
  done
fi

# Optional GRE key: both ends must match; packets with another key are dropped.
KEY=()
[ -z "${GRE_KEY:-}" ] || KEY=(key "${GRE_KEY}")

# (re)create the tunnel device (idempotent). ip6_gre autoloads (rtnl-link-ip6gre).
ip link del "${DEV}" 2>/dev/null || true
if [ "${V6}" = 1 ]; then
  ip link add "${DEV}" type ip6gre \
    local "${LOCAL_PUB}" remote "${REMOTE_PUB}" ttl 255 "${KEY[@]}"
else
  ip link add "${DEV}" type gre \
    local "${LOCAL_PUB}" remote "${REMOTE_PUB}" ttl 255 "${KEY[@]}" \
    encap fou encap-sport auto encap-dport "${FOU_PORT}"
fi
ip addr add "${TUN_ADDR}" dev "${DEV}"
ip link set "${DEV}" mtu "${MTU}" up

# Disable GRO on the underlay NIC. GRO mis-coalesces GRE-in-UDP (FOU) packets on
# some drivers, corrupting them — they're dropped at the receiver's UDP layer
# (UdpInErrors), which collapses TCP to ~1 Mbit while UDP looks fine. See docs/GRO.md.
# Plain GRE over IPv6 is not UDP, so there is nothing to fix there.
if [ "${V6}" = 0 ]; then
  ethtool -K "${UL}" gro off 2>/dev/null || true
fi

# Accept forwarded traffic in/out of the tunnel. Deleted and re-inserted so it is
# always at the top, ahead of any DROP that Docker/ufw added since the last run.
# TCP MSS clamp on the forward path (both directions) — prevents PMTUD black holes
for DIR in "-o" "-i"; do
  iptables -D FORWARD "${DIR}" "${DEV}" -j ACCEPT 2>/dev/null || true
  iptables -I FORWARD "${DIR}" "${DEV}" -j ACCEPT
  iptables -t mangle -C FORWARD "${DIR}" "${DEV}" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables -t mangle -A FORWARD "${DIR}" "${DEV}" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu
done

# Optional static routes through the tunnel (space-separated CIDRs)
if [ -n "${ROUTES:-}" ]; then
  read -ra _routes <<<"${ROUTES}"
  for net in "${_routes[@]}"; do
    ip route replace "${net}" dev "${DEV}"
  done
fi

# Optional MASQUERADE for traffic exiting via this node. Without NAT_OUT, match
# anything leaving by an interface other than the tunnel (no NIC-name guessing).
if [ -n "${NAT_SRC:-}" ]; then
  if [ -n "${NAT_OUT:-}" ]; then OUT=(-o "${NAT_OUT}"); else OUT=(! -o "${DEV}"); fi
  iptables -t nat -C POSTROUTING -s "${NAT_SRC}" "${OUT[@]}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "${NAT_SRC}" "${OUT[@]}" -j MASQUERADE
fi

if [ "${V6}" = 1 ]; then
  echo "golden-gre: ${DEV} up — ${TUN_ADDR} -> ${REMOTE_PUB} (gre over ipv6, mtu ${MTU})"
else
  echo "golden-gre: ${DEV} up — ${TUN_ADDR} -> ${REMOTE_PUB} (fou udp/${FOU_PORT}, mtu ${MTU})"
fi
