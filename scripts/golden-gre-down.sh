#!/usr/bin/env bash
# Golden GRE — tear down one GRE-over-FOU tunnel.
# Usage: golden-gre-down.sh <instance>
set -uo pipefail

NAME="${1:?usage: golden-gre-down.sh <instance>}"
CONF="/etc/golden-gre/${NAME}.conf"
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

DEV="${DEV:-}"
FOU_PORT="${FOU_PORT:-}"

if [ -n "$DEV" ]; then
  for DIR in "-o" "-i"; do
    iptables -t mangle -D FORWARD "${DIR}" "${DEV}" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  done
  if [ -n "${NAT_SRC:-}" ]; then
    iptables -t nat -D POSTROUTING -s "${NAT_SRC}" -o "${NAT_OUT:-eth0}" -j MASQUERADE 2>/dev/null || true
  fi
  ip link del "${DEV}" 2>/dev/null || true
fi

# Remove this tunnel's FOU listener (each tunnel uses a unique port)
if [ -n "$FOU_PORT" ]; then
  ip fou del port "${FOU_PORT}" 2>/dev/null || true
fi

echo "golden-gre: ${NAME} down"
exit 0
