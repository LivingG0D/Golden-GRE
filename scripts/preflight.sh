#!/usr/bin/env bash
# Golden GRE preflight — check a host (and optionally a tunnel config) is ready.
# Usage: preflight.sh [instance]
set -uo pipefail

g(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
b(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
w(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
FAIL=0

echo "== kernel modules =="
for m in fou ip_gre; do
  if modprobe "$m" 2>/dev/null; then g "$m loadable"; else b "$m not loadable"; fi
done

echo "== tools =="
for t in ip iptables; do
  if command -v "$t" >/dev/null 2>&1; then g "$t present"; else b "$t missing"; fi
done
if command -v ethtool >/dev/null 2>&1; then g "ethtool present"; else w "ethtool missing (turns off GSO on the tunnel device; install it)"; fi
RELAY="${GOLDEN_GRE_RELAY:-/usr/local/sbin/golden-gre-relay}"
if [ -x "$RELAY" ]; then g "relay binary $RELAY"; else b "relay binary $RELAY missing (run install.sh; it needs gcc)"; fi

echo "== sysctl =="
cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
if [ "$cc" = bbr ]; then g "tcp_congestion_control = bbr"; else w "tcp_congestion_control = $cc (run install.sh for bbr)"; fi
fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
if [ "$fwd" = 1 ]; then g "ip_forward = 1"; else w "ip_forward = $fwd (needed only when routing through the tunnel)"; fi

NAME="${1:-}"
if [ -n "$NAME" ]; then
  CONF="/etc/golden-gre/${NAME}.conf"
  echo "== config: $CONF =="
  if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
    for v in DEV LOCAL_PUB REMOTE_PUB TUN_ADDR; do
      if [ -n "${!v:-}" ]; then g "$v=${!v}"; else b "$v not set"; fi
    done
    case "${LOCAL_PUB:-}${REMOTE_PUB:-}" in *:*) b "LOCAL_PUB and REMOTE_PUB must be IPv4 addresses" ;; esac
    if [ -n "${LOCAL_PUB:-}" ]; then
      if ip -4 -o addr show | grep -qw "${LOCAL_PUB}"; then g "${LOCAL_PUB} is configured on this host"; else b "${LOCAL_PUB} is not an address of this host (the relay binds it)"; fi
    fi
    FACADE="${FACADE:-dns}"
    case "$FACADE" in
      dns)
        port="${DNS_PORT:-53}"
        if [ -n "$(ss -Hlun "sport = :${port}" "src ${LOCAL_PUB:-0.0.0.0}" 2>/dev/null)" ]; then
          b "UDP ${LOCAL_PUB:-*}:${port} is already in use (another relay or a DNS server); use a different LOCAL_PUB or DNS_PORT"
        else
          g "UDP ${LOCAL_PUB:-*}:${port} is free for the relay"
        fi
        w "verify the path end-to-end with: tcpdump -ni any udp port ${port}  (run on the peer while this side sends)"
        ;;
      icmp) w "verify the path end-to-end with: tcpdump -ni any icmp  (run on the peer while this side sends)" ;;
      *) b "FACADE must be dns or icmp" ;;
    esac
  else
    b "config not found — create it from examples/"
  fi
fi

echo
if [ "$FAIL" = 0 ]; then echo "preflight: OK"; else echo "preflight: problems found"; exit 1; fi
