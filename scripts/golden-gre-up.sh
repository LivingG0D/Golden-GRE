#!/usr/bin/env bash
# Golden GRE — bring up one GRE-over-FOU tunnel from /etc/golden-gre/<instance>.conf
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
: "${FOU_PORT:?FOU_PORT not set in $CONF}"
MTU="${MTU:-1400}"

# fou has no module alias, so `ip fou add` cannot autoload it. ip_gre does
# autoload (rtnl-link-gre) at `ip link add type gre`.
modprobe fou

# FOU decapsulation listener (idempotent)
ip fou show 2>/dev/null | grep -q "port ${FOU_PORT} " \
  || ip fou add port "${FOU_PORT}" ipproto 47

# (re)create the tunnel device (idempotent)
ip link del "${DEV}" 2>/dev/null || true
ip link add "${DEV}" type gre \
  local "${LOCAL_PUB}" remote "${REMOTE_PUB}" ttl 255 \
  encap fou encap-sport auto encap-dport "${FOU_PORT}"
ip addr add "${TUN_ADDR}" dev "${DEV}"
ip link set "${DEV}" mtu "${MTU}" up

# Disable GRO on the underlay NIC. GRO mis-coalesces GRE-in-UDP (FOU) packets on
# some drivers, corrupting them — they're dropped at the receiver's UDP layer
# (UdpInErrors), which collapses TCP to ~1 Mbit while UDP looks fine. See docs/GRO.md.
# Best-effort: at early boot the route may not exist yet, which must not abort bringup.
UL="$(ip route get "${REMOTE_PUB}" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')" || true
if [ -n "${UL}" ]; then ethtool -K "${UL}" gro off 2>/dev/null || true; fi

# Accept forwarded traffic in/out of the tunnel. Inserted at the top so a FORWARD
# policy of DROP (Docker, ufw) does not silently eat routed traffic.
# TCP MSS clamp on the forward path (both directions) — prevents PMTUD black holes
for DIR in "-o" "-i"; do
  iptables -C FORWARD "${DIR}" "${DEV}" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD "${DIR}" "${DEV}" -j ACCEPT
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

echo "golden-gre: ${DEV} up — ${TUN_ADDR} -> ${REMOTE_PUB} (fou udp/${FOU_PORT}, mtu ${MTU})"
