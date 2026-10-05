#!/usr/bin/env bash
# Loopback test of the relay: two relays on 127.0.0.2/127.0.0.3 and two stand-in tunnel endpoints.
# Checks both directions, bulk delivery and sizes, and (dns) that frames from a non-peer address are
# ignored. The icmp facade needs root (raw socket) and is skipped otherwise. Builds the relay itself.
# Ports are per run and checked free first: on a host that already runs a tunnel (whose relay holds
# 127.0.0.1:5601 by default) fixed ports would send this test's datagrams into the live relay.
# To be safe on such a host, run it in its own network namespace: unshare -n sh -c 'ip link set lo up; tests/relay.sh'
set -euo pipefail

cd "$(dirname "$0")/.."
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "ok: $*"; }

base=$(( 20000 + $$ % 20000 ))
RELAY_A=$base RELAY_B=$(( base + 1 )) END_A=$(( base + 2 )) END_B=$(( base + 3 )) DNSP=$(( base + 4 ))
for p in "$RELAY_A" "$RELAY_B" "$END_A" "$END_B" "$DNSP"; do
  [ -z "$(ss -Hlun "sport = :${p}")" ] || fail "UDP port $p is already in use"
done

tmp="$(mktemp -d)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT

gcc -O2 -Wall -Wextra -Werror -o "$tmp/relay" relay/golden-gre-relay.c
ok "relay builds without warnings"

run_facade() {
  local facade="$1"
  "$tmp/relay" --facade "$facade" --bind 127.0.0.2 --peer 127.0.0.3 --local "127.0.0.1:$RELAY_A" --port "$DNSP" >"$tmp/a.log" 2>&1 &
  pids+=("$!")
  "$tmp/relay" --facade "$facade" --bind 127.0.0.3 --peer 127.0.0.2 --local "127.0.0.1:$RELAY_B" --reply "127.0.0.1:$END_B" --port "$DNSP" >"$tmp/b.log" 2>&1 &
  pids+=("$!")
  sleep 0.5
  for p in "${pids[@]}"; do
    kill -0 "$p" 2>/dev/null || fail "a relay did not start: $(cat "$tmp/a.log" "$tmp/b.log")"
  done
  python3 - "$facade" "$RELAY_A" "$RELAY_B" "$END_A" "$END_B" "$DNSP" <<'PY'
import socket, struct, sys, threading, time

facade = sys.argv[1]
relay_a, relay_b, end_a, end_b, dnsp = (int(x) for x in sys.argv[2:7])

def udp(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port))
    s.settimeout(2)
    return s

a, b = udp(end_a), udp(end_b)
# relay B was started with --reply, so b never has to send first; relay A learns its endpoint from the
# first local packet, so a registers itself
a.sendto(b"reg-a", ("127.0.0.1", relay_a))
time.sleep(0.3)
for s in (a, b):
    s.settimeout(0.3)
    try:
        while True:
            s.recvfrom(2048)
    except socket.timeout:
        pass
    s.settimeout(2)

a.sendto(b"from-a", ("127.0.0.1", relay_a))
assert b.recvfrom(2048)[0] == b"from-a", "a -> b"
b.sendto(b"from-b", ("127.0.0.1", relay_b))
assert a.recvfrom(2048)[0] == b"from-b", "b -> a"

N, size = 3000, 1300
got = [0]

def drain():
    b.settimeout(0.7)
    try:
        while True:
            d = b.recvfrom(2048)[0]
            assert len(d) == size, "payload size changed: %d" % len(d)
            got[0] += 1
    except socket.timeout:
        pass

t = threading.Thread(target=drain)
t.start()
for i in range(N):
    a.sendto(i.to_bytes(4, "big") + b"x" * (size - 4), ("127.0.0.1", relay_a))
    if i % 100 == 99:
        time.sleep(0.002)
t.join()
assert got[0] >= 0.9 * N, "bulk delivered only %d of %d" % (got[0], N)

if facade == "dns":
    # a well-formed frame from an address that is not the peer must not reach the endpoint
    question = b"\x05probe\x04test\x00" + struct.pack("!HH", 16, 1)
    payload = b"intruder"
    frame = (struct.pack("!HHHHHH", 1, 0x0100, 1, 0, 0, 1) + question
             + b"\x00" + struct.pack("!HHIH", 41, 4096, 0, len(payload)) + payload)
    x = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    x.bind(("127.0.0.4", 0))
    x.sendto(frame, ("127.0.0.2", dnsp))
    a.settimeout(0.5)
    try:
        a.recvfrom(2048)
        raise AssertionError("frame from a non-peer address was delivered")
    except socket.timeout:
        pass
print("delivered %d of %d" % (got[0], N))
PY
  kill "${pids[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
  pids=()
}

run_facade dns
ok "dns facade: both directions (one end --reply, one learned), bulk delivery, sizes intact, non-peer frame ignored"

if [ "$(id -u)" -eq 0 ]; then
  run_facade icmp
  ok "icmp facade: both directions, bulk delivery, sizes intact"
else
  echo "skip: icmp facade needs root"
fi

echo "relay: PASS"
