#!/bin/bash
# cpu_at.sh <epoch> <secs> -- print host CPU use over <secs> starting at <epoch>
# shellcheck disable=SC1091
. /tmp/tb/common.sh
waitfor "$1"
echo "cpu: $(cpu "$2")"
