#!/usr/bin/env bash
# Golden GRE — tear down one GRE-over-FOU tunnel.
# Usage: golden-gre-down.sh <instance>
set -uo pipefail

NAME="${1:?usage: golden-gre-down.sh <instance>}"
CONF="/etc/golden-gre/${NAME}.conf"
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

if [ -n "${DEV:-}" ]; then
  for DIR in "-o" "-i"; do
    iptables -D FORWARD "${DIR}" "${DEV}" -j ACCEPT 2>/dev/null || true
    iptables -t mangle -D FORWARD "${DIR}" "${DEV}" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  done
  if [ -n "${NAT_SRC:-}" ]; then
    if [ -n "${NAT_OUT:-}" ]; then OUT=(-o "${NAT_OUT}"); else OUT=(! -o "${DEV}"); fi
    iptables -t nat -D POSTROUTING -s "${NAT_SRC}" "${OUT[@]}" -j MASQUERADE 2>/dev/null || true
  fi
  ip link del "${DEV}" 2>/dev/null || true
fi

# Remove this tunnel's FOU listener (each tunnel uses a unique port) and its
# INPUT rules
if [ -n "${FOU_PORT:-}" ]; then
  ip fou del port "${FOU_PORT}" 2>/dev/null || true
  if [ -n "${REMOTE_PUB:-}" ]; then
    iptables -D INPUT -p udp --dport "${FOU_PORT}" -s "${REMOTE_PUB}" -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p udp --dport "${FOU_PORT}" ! -s "${REMOTE_PUB}" -j DROP 2>/dev/null || true
  fi
fi

echo "golden-gre: ${NAME} down"
exit 0
