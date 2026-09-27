#!/usr/bin/env bash
# systemd wiring test for a real host with systemd as PID 1 (the CI runner).
# install.sh must already have run. Starts a throwaway tunnel toward an
# unreachable documentation address and checks that the check timer follows the
# tunnel's lifecycle and that a failing check leaves its unit failed.
set -euo pipefail

fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "ok: $*"; }

N="unit-$$"
cleanup() {
  systemctl disable --now "golden-gre-check@$N.timer" 2>/dev/null || true
  systemctl stop "golden-gre@$N" 2>/dev/null || true
  systemctl reset-failed "golden-gre-check@$N.service" 2>/dev/null || true
  rm -f "/etc/golden-gre/$N.conf"
}
trap cleanup EXIT

src="$(ip route get 192.0.2.1 | sed -n 's/.* src \([^ ]*\).*/\1/p')"
cat >"/etc/golden-gre/$N.conf" <<EOF
DEV=ggu$$
LOCAL_PUB=$src
REMOTE_PUB=192.0.2.1
TUN_ADDR=10.250.250.1/30
FOU_PORT=5599
EOF

systemctl enable "golden-gre-check@$N.timer"
systemctl start "golden-gre@$N"
systemctl is-active -q "golden-gre-check@$N.timer" || fail "timer did not start with the tunnel"
ok "enabled timer starts with the tunnel"

systemctl start "golden-gre-check@$N.service" && fail "check passed with an unreachable peer"
systemctl is-failed -q "golden-gre-check@$N.service" || fail "failed check did not leave its unit failed"
ok "unreachable peer leaves the check unit failed"

systemctl stop "golden-gre@$N"
systemctl is-active -q "golden-gre-check@$N.timer" && fail "timer still running after the tunnel stopped"
ok "timer stops with the tunnel"

echo "systemd: PASS"
