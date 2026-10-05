#!/usr/bin/env bash
# Golden GRE installer — builds the relay, installs scripts, the systemd template, and sysctl tuning.
# Idempotent. Run as root on each server. Needs gcc to build the relay (build time only).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "golden-gre: run as root (sudo ./install.sh)" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
command -v gcc >/dev/null 2>&1 || { echo "golden-gre: gcc is needed to build the relay (apt install gcc)" >&2; exit 1; }

echo "==> building the relay"
gcc -O2 -Wall -o /usr/local/sbin/golden-gre-relay "$SRC/relay/golden-gre-relay.c"

echo "==> installing scripts to /usr/local/sbin"
install -m 0755 "$SRC/scripts/golden-gre-up.sh"    /usr/local/sbin/golden-gre-up.sh
install -m 0755 "$SRC/scripts/golden-gre-down.sh"  /usr/local/sbin/golden-gre-down.sh
install -m 0755 "$SRC/scripts/golden-gre-relay.sh" /usr/local/sbin/golden-gre-relay.sh
install -m 0755 "$SRC/scripts/preflight.sh"        /usr/local/sbin/golden-gre-preflight
install -m 0755 "$SRC/scripts/golden-gre-check.sh" /usr/local/sbin/golden-gre-check

echo "==> installing systemd template units"
install -m 0644 "$SRC"/systemd/golden-gre@.service "$SRC"/systemd/golden-gre-check@.service \
  "$SRC"/systemd/golden-gre-check@.timer /etc/systemd/system/

echo "==> installing sysctl tuning"
install -m 0644 "$SRC/sysctl/99-golden-gre.conf" /etc/sysctl.d/99-golden-gre.conf
sysctl --system >/dev/null

echo "==> preparing /etc/golden-gre"
install -d -m 0750 /etc/golden-gre

systemctl daemon-reload

cat <<'NEXT'

Golden GRE installed. 🥇

Next:
  1. Create a tunnel config:   /etc/golden-gre/<name>.conf
     (see examples/*.conf.example)
  2. Preflight (optional):     golden-gre-preflight <name>
  3. Start + enable on boot:   systemctl enable --now golden-gre@<name>
  4. Verify:                   systemctl status golden-gre@<name>
  5. Health check (optional):  systemctl enable golden-gre-check@<name>.timer

NEXT
