#!/usr/bin/env bash
# Bring a test tunnel up or down by hand, for debugging.
# usage: bench/tun.sh up <method> [shim] | down <method>
set -u
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case ${1:-} in
  up) tun_up "${2:?method}" "${3:-}" && echo "up: $2 ${3:-}" ;;
  down) tun_down "${2:?method}" ;;
  *) echo "usage: $0 up <method> [shim] | down <method>" >&2; exit 1 ;;
esac
