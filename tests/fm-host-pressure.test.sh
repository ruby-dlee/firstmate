#!/usr/bin/env bash
# Behavior tests for contemporaneous host-pressure evidence capture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOST_PRESSURE="$ROOT/bin/fm-host-pressure.sh"
fm_test_tmproot_into TMP_ROOT fm-host-pressure
mkdir -p "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/uptime" <<'SH'
#!/usr/bin/env bash
printf '16:00 up 4 days, load averages: 30.00 25.00 20.00\n'
SH
cat > "$TMP_ROOT/bin/vm_stat" <<'SH'
#!/usr/bin/env bash
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages swapped out: 4242.\n'
SH
chmod +x "$TMP_ROOT/bin/uptime" "$TMP_ROOT/bin/vm_stat"

out=$(
  FM_HOST_PRESSURE_TEST_LAB=firstmate-host-pressure-test-lab-v1 \
    FM_HOST_PRESSURE_UPTIME_BIN="$TMP_ROOT/bin/uptime" \
    FM_HOST_PRESSURE_VM_STAT_BIN="$TMP_ROOT/bin/vm_stat" \
    "$HOST_PRESSURE"
) || fail "host-pressure helper rejected valid instruments"
assert_contains "$out" 'load averages: 30.00 25.00 20.00' "uptime load was not recorded"
assert_contains "$out" 'Pages swapped out: 4242.' "vm_stat swap evidence was not recorded"
pass "host-pressure evidence records uptime and vm_stat together"

if FM_HOST_PRESSURE_UPTIME_BIN="$TMP_ROOT/bin/uptime" "$HOST_PRESSURE" >/dev/null 2>&1; then
  fail "host-pressure accepted an unguarded command override"
fi
pass "host-pressure instrument overrides are test-lab only"

printf 'all fm-host-pressure tests passed\n'
