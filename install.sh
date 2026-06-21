#!/usr/bin/env bash
# Golden GRE installer — installs scripts, the systemd template, and sysctl tuning.
# Idempotent. Run as root on each server.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "golden-gre: run as root (sudo ./install.sh)" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "==> installing scripts to /usr/local/sbin"
install -m 0755 "$SRC/scripts/golden-gre-up.sh"   /usr/local/sbin/golden-gre-up.sh
install -m 0755 "$SRC/scripts/golden-gre-down.sh" /usr/local/sbin/golden-gre-down.sh
install -m 0755 "$SRC/scripts/preflight.sh"       /usr/local/sbin/golden-gre-preflight

echo "==> installing systemd template unit"
install -m 0644 "$SRC/systemd/golden-gre@.service" /etc/systemd/system/golden-gre@.service

echo "==> installing sysctl tuning"
install -m 0644 "$SRC/sysctl/99-golden-gre.conf" /etc/sysctl.d/99-golden-gre.conf
sysctl --system >/dev/null

echo "==> preparing /etc/golden-gre"
mkdir -p /etc/golden-gre
chmod 0750 /etc/golden-gre

systemctl daemon-reload

cat <<'NEXT'

Golden GRE installed. 🥇

Next:
  1. Create a tunnel config:   /etc/golden-gre/<name>.conf
     (see examples/*.conf.example)
  2. Preflight (optional):     golden-gre-preflight <name>
  3. Start + enable on boot:   systemctl enable --now golden-gre@<name>
  4. Verify:                   systemctl status golden-gre@<name>

NEXT
