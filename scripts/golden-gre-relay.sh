#!/usr/bin/env bash
# Golden GRE — run the relay for one tunnel, in the foreground (it is the systemd unit's main process).
# Without systemd: golden-gre-up.sh <instance>, then this script in the background.
# Usage: golden-gre-relay.sh <instance>
set -euo pipefail

NAME="${1:?usage: golden-gre-relay.sh <instance>}"
CONF="/etc/golden-gre/${NAME}.conf"
[ -r "$CONF" ] || { echo "golden-gre: missing config $CONF" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"
: "${LOCAL_PUB:?LOCAL_PUB not set in $CONF}"
: "${REMOTE_PUB:?REMOTE_PUB not set in $CONF}"

RELAY="${GOLDEN_GRE_RELAY:-/usr/local/sbin/golden-gre-relay}"
[ -x "$RELAY" ] || { echo "golden-gre: relay binary $RELAY not found (run install.sh)" >&2; exit 1; }

exec "$RELAY" --facade "${FACADE:-dns}" --bind "${LOCAL_PUB}" --peer "${REMOTE_PUB}" \
  --local "127.0.0.1:${RELAY_PORT:-5601}" --reply "127.0.0.1:${FOU_PORT:-5599}" --port "${DNS_PORT:-53}"
