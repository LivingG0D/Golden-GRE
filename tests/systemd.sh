#!/usr/bin/env bash
# systemd wiring test for a real host with systemd as PID 1 (the CI runner).
# install.sh must already have run. Starts a throwaway tunnel toward an
# unreachable documentation address and checks that the check timer follows the
# tunnel's lifecycle, that a failing check leaves its unit failed, and that
# stopping the tunnel cancels an in-flight check without marking it failed.
set -euo pipefail

fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "ok: $*"; }

# Instance, device and port are per run; refuse to start on any collision rather
# than reuse (and later tear down) state this test does not own.
N="unit-$$" DEV="ggu$$" PORT=$(( 20000 + $$ % 20000 ))
[ -e "/etc/golden-gre/$N.conf" ] && fail "/etc/golden-gre/$N.conf already exists"
ip link show "$DEV" >/dev/null 2>&1 && fail "device $DEV already exists"
if ip fou show | grep -q "port ${PORT} " || [ -n "$(ss -Hlun "sport = :${PORT}")" ]; then
  fail "UDP port $PORT already in use"
fi

cleanup() {
  systemctl disable --now "golden-gre-check@$N.timer" 2>/dev/null || true
  systemctl stop "golden-gre@$N" 2>/dev/null || true
  systemctl reset-failed "golden-gre-check@$N.service" 2>/dev/null || true
  rm -f "/etc/golden-gre/$N.conf"
}
trap cleanup EXIT

src="$(ip route get 192.0.2.1 | sed -n 's/.* src \([^ ]*\).*/\1/p')"
cat >"/etc/golden-gre/$N.conf" <<EOF
DEV=$DEV
LOCAL_PUB=$src
REMOTE_PUB=192.0.2.1
TUN_ADDR=10.250.250.1/30
FOU_PORT=$PORT
EOF

systemctl enable "golden-gre-check@$N.timer"
systemctl start "golden-gre@$N"
systemctl is-active -q "golden-gre-check@$N.timer" || fail "timer did not start with the tunnel"
ok "enabled timer starts with the tunnel"

systemctl start "golden-gre-check@$N.service" && fail "check passed with an unreachable peer"
systemctl is-failed -q "golden-gre-check@$N.service" || fail "failed check did not leave its unit failed"
ok "unreachable peer leaves the check unit failed"
systemctl reset-failed "golden-gre-check@$N.service"

# A check against an unreachable peer runs ~4 s. Stop the tunnel while it runs.
systemctl start --no-block "golden-gre-check@$N.service"
for _ in $(seq 20); do
  [ "$(systemctl is-active "golden-gre-check@$N.service")" = activating ] && break
  sleep 0.1
done
[ "$(systemctl is-active "golden-gre-check@$N.service")" = activating ] || fail "check never started running"
systemctl stop "golden-gre@$N"
sleep 6   # longer than one check run, so an uncancelled check would have finished
systemctl is-failed -q "golden-gre-check@$N.service" && fail "stopping the tunnel left an in-flight check failed"
systemctl is-active -q "golden-gre-check@$N.service" && fail "in-flight check still running after the tunnel stopped"
ok "stopping the tunnel cancels an in-flight check cleanly"

systemctl is-active -q "golden-gre-check@$N.timer" && fail "timer still running after the tunnel stopped"
ok "timer stops with the tunnel"

echo "systemd: PASS"
