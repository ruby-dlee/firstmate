#!/usr/bin/env bash
# Record contemporaneous host-load and virtual-memory evidence without
# interpreting it as a code diagnosis.
# Usage: fm-host-pressure.sh
set -u

UPTIME_BIN=${FM_HOST_PRESSURE_UPTIME_BIN:-uptime}
VM_STAT_BIN=${FM_HOST_PRESSURE_VM_STAT_BIN:-vm_stat}

if [ -n "${FM_HOST_PRESSURE_UPTIME_BIN:-}${FM_HOST_PRESSURE_VM_STAT_BIN:-}" ] \
  && [ "${FM_HOST_PRESSURE_TEST_LAB:-}" != firstmate-host-pressure-test-lab-v1 ]; then
  echo "error: host-pressure command overrides are test-lab only" >&2
  exit 2
fi

observed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
printf 'host-pressure observed_at=%s\n' "$observed_at"

if uptime_output=$("$UPTIME_BIN" 2>&1); then
  printf 'uptime: %s\n' "$uptime_output"
else
  printf 'uptime: unavailable (%s)\n' "$uptime_output"
  rc=1
fi

if vm_output=$("$VM_STAT_BIN" 2>&1); then
  printf 'vm_stat:\n%s\n' "$vm_output"
else
  printf 'vm_stat: unavailable (%s)\n' "$vm_output"
  rc=1
fi

exit "${rc:-0}"
