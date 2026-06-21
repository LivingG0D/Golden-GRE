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

modprobe fou
modprobe ip_gre

# FOU decapsulation listener (idempotent)
ip fou show 2>/dev/null | grep -q "port ${FOU_PORT} " \
  || ip fou add port "${FOU_PORT}" ipproto 47

# (re)create the tunnel device (idempotent)
ip link del "${DEV}" 2>/dev/null || true
ip link add "${DEV}" type gre \
  local "${LOCAL_PUB}" remote "${REMOTE_PUB}" ttl 255 \
  encap fou encap-sport "${FOU_PORT}" encap-dport "${FOU_PORT}"
ip addr add "${TUN_ADDR}" dev "${DEV}"
ip link set "${DEV}" mtu "${MTU}" up

# TCP MSS clamp on the forward path (both directions) — prevents PMTUD black holes
for DIR in "-o" "-i"; do
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

# Optional MASQUERADE for traffic exiting via this node
if [ -n "${NAT_SRC:-}" ]; then
  OUT="${NAT_OUT:-eth0}"
  iptables -t nat -C POSTROUTING -s "${NAT_SRC}" -o "${OUT}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "${NAT_SRC}" -o "${OUT}" -j MASQUERADE
fi

echo "golden-gre: ${DEV} up — ${TUN_ADDR} -> ${REMOTE_PUB} (fou udp/${FOU_PORT}, mtu ${MTU})"
