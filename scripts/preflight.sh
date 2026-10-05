#!/usr/bin/env bash
# Golden GRE preflight — check a host (and optionally a tunnel config) is ready.
# Usage: preflight.sh [instance]
set -uo pipefail

g(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
b(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
w(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
FAIL=0

# With an instance, its config says which underlay (so which modules and tools) to check.
NAME="${1:-}"
V6=""   # 1 = IPv6 underlay (plain GRE), 0 = IPv4 (GRE-over-FOU), empty = no instance
if [ -n "$NAME" ] && [ -r "/etc/golden-gre/${NAME}.conf" ]; then
  # shellcheck source=/dev/null
  V6="$(. "/etc/golden-gre/${NAME}.conf"; case "${REMOTE_PUB:-}" in *:*) echo 1 ;; *) echo 0 ;; esac)"
fi

echo "== kernel modules =="
if [ "$V6" = 1 ]; then mods=(ip6_gre); else mods=(fou ip_gre); fi
for m in "${mods[@]}"; do
  if modprobe "$m" 2>/dev/null; then g "$m loadable"; else b "$m not loadable"; fi
done
if [ "$V6" != 1 ]; then
  if modprobe ip6_gre 2>/dev/null; then g "ip6_gre loadable (IPv6 underlay)"; else w "ip6_gre not loadable (needed only for an IPv6 underlay)"; fi
fi

echo "== tools =="
tools=(ip iptables)
if [ "$V6" = 1 ]; then tools+=(ip6tables); fi
for t in "${tools[@]}"; do
  if command -v "$t" >/dev/null 2>&1; then g "$t present"; else b "$t missing"; fi
done

echo "== sysctl =="
cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
if [ "$cc" = bbr ]; then g "tcp_congestion_control = bbr"; else w "tcp_congestion_control = $cc (run install.sh for bbr)"; fi
fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
if [ "$fwd" = 1 ]; then g "ip_forward = 1"; else w "ip_forward = $fwd (needed only when routing through the tunnel)"; fi

if [ -n "$NAME" ]; then
  CONF="/etc/golden-gre/${NAME}.conf"
  echo "== config: $CONF =="
  if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
    vars=(DEV LOCAL_PUB REMOTE_PUB TUN_ADDR)
    if [ "$V6" != 1 ]; then vars+=(FOU_PORT); fi
    for v in "${vars[@]}"; do
      if [ -n "${!v:-}" ]; then g "$v=${!v}"; else b "$v not set"; fi
    done
    if [ "$V6" = 1 ]; then
      w "verify the path end-to-end with: tcpdump -ni any ip6 proto 47  (run on the peer while this side sends)"
    elif [ -n "${FOU_PORT:-}" ]; then
      w "verify the path end-to-end with: tcpdump -ni any udp port ${FOU_PORT}  (run on the peer while this side sends)"
    fi
  else
    b "config not found — create it from examples/"
  fi
fi

echo
if [ "$FAIL" = 0 ]; then echo "preflight: OK"; else echo "preflight: problems found"; exit 1; fi
