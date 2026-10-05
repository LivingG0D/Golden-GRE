#!/bin/bash
# Helpers sourced by the remote scripts.
waitfor() { while [ "$(date +%s)" -lt "$1" ]; do sleep 0.2; done; }

# cpu <secs> -- whole-host CPU use over the interval: busy = user+nice+system+irq+softirq
cpu() {
  local a b
  a=$(awk '/^cpu /{print $2+$3+$4+$7+$8, $9, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat)
  sleep "$1"
  b=$(awk '/^cpu /{print $2+$3+$4+$7+$8, $9, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat)
  echo "$a $b" | awk '{t = $6 - $3; printf "busy=%.0f%% steal=%.0f%%", 100 * ($4 - $1) / t, 100 * ($5 - $2) / t}'
}
