#!/usr/bin/env bash
# Golden GRE — liveness check for one tunnel: ping the peer's overlay address.
# Exits 1 when the peer does not answer, so a systemd timer shows the failure.
# Usage: golden-gre-check.sh <instance>
set -euo pipefail

NAME="${1:?usage: golden-gre-check.sh <instance>}"
CONF="/etc/golden-gre/${NAME}.conf"
[ -r "$CONF" ] || { echo "golden-gre: missing config $CONF" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"
: "${DEV:?DEV not set in $CONF}"
: "${TUN_ADDR:?TUN_ADDR not set in $CONF}"

# Peer = the other host of a /30 (or /31). Other prefix lengths need PEER_ADDR.
if [ -z "${PEER_ADDR:-}" ]; then
  ip4="${TUN_ADDR%/*}" len="${TUN_ADDR#*/}"
  last="${ip4##*.}"
  case "$len" in
    30) PEER_ADDR="${ip4%.*}.$(( (last & ~3) + 3 - (last & 3) ))" ;;
    31) PEER_ADDR="${ip4%.*}.$(( last ^ 1 ))" ;;
    *) echo "golden-gre: set PEER_ADDR in $CONF (TUN_ADDR is not a /30 or /31)" >&2; exit 1 ;;
  esac
fi

if ping -c 3 -W 2 -q -I "${DEV}" "${PEER_ADDR}" >/dev/null 2>&1; then
  echo "golden-gre: ${NAME} ok — ${PEER_ADDR} answers via ${DEV}"
else
  echo "golden-gre: ${NAME} DOWN — no reply from ${PEER_ADDR} via ${DEV}" >&2
  exit 1
fi
