#!/usr/bin/env bash
# Behavior tests for fm-macos-permissions.sh's read-only reporting and pane URLs.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-macos-permissions.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-macos-permissions-tests)

make_world() {
  local world="$TMP_ROOT/$1" fakebin
  mkdir -p "$world/home/Library/Mail" "$world/home/.no-mistakes/bin"
  : > "$world/home/.no-mistakes/bin/no-mistakes"
  fakebin=$(fm_fakebin "$world")

  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_UNAME:-Darwin}"
SH
  cat > "$fakebin/ls" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_FDA:-missing}" = granted ]; then
  exit 0
fi
printf 'ls: protected path: Operation not permitted\n' >&2
exit 1
SH
  cat > "$fakebin/sqlite3" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_TCC_READABLE:-no}" != yes ]; then
  printf '%s\n' 'Error: authorization denied' >&2
  exit 1
fi
case "$*" in
  *kTCCServiceAppleEvents*com.mitchellh.ghostty*) printf 'com.mitchellh.ghostty|com.apple.systemevents|2\n' ;;
  *kTCCServiceScreenCapture*com.kunchenguid.no-mistakes*) printf '2\n' ;;
  *kTCCServiceAccessibility*com.kunchenguid.no-mistakes*) printf '0\n' ;;
  *'SELECT 1 FROM access LIMIT 1;'*) printf '1\n' ;;
esac
SH
  cat > "$fakebin/codesign" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_AUTOMATION_ENTITLEMENT:-missing}" = present ]; then
  printf '%s\n' '<key>com.apple.security.automation.apple-events</key>'
fi
exit 0
SH
  cat > "$fakebin/open" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_FAKE_OPEN_LOG"
SH
  cat > "$fakebin/tccutil" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'tccutil must never be invoked' >> "$FM_FAKE_MUTATION_LOG"
exit 99
SH
  chmod +x "$fakebin"/* "$world/home/.no-mistakes/bin/no-mistakes"
  ln -s "$world/home/.no-mistakes/bin/no-mistakes" "$fakebin/no-mistakes"
  printf '%s\n' "$world"
}

run_report() {
  local world=$1
  shift
  HOME="$world/home" PATH="$world/fakebin:$BASE_PATH" \
    __CFBundleIdentifier=com.mitchellh.ghostty "$SCRIPT" "$@"
}

test_missing_probe_is_honest() {
  local world out
  world=$(make_world missing)
  out=$(FM_FAKE_FDA=missing FM_FAKE_TCC_READABLE=no run_report "$world")

  assert_contains "$out" 'current protected-path probe: MISSING' \
    'protected-path denial was not reported'
  assert_contains "$out" 'readable TCC databases: 0' \
    'TCC database chicken-and-egg was hidden'
  assert_contains "$out" 'Screen Recording and Accessibility therefore remain UNKNOWN' \
    'undetectable grants were guessed'
  assert_contains "$out" 'Automation status is always PER TARGET' \
    'Automation was presented as a blanket grant'
  assert_contains "$out" 'BLOCKED: ENTITLEMENT MISSING' \
    'missing no-mistakes Apple Events entitlement was hidden'
  pass 'missing and undetectable grants are reported honestly'
}

test_readable_database_reports_stored_rows() {
  local world out
  world=$(make_world readable)
  mkdir -p "$world/home/Library/Application Support/com.apple.TCC"
  : > "$world/home/Library/Application Support/com.apple.TCC/TCC.db"

  out=$(FM_FAKE_FDA=granted FM_FAKE_TCC_READABLE=yes run_report "$world")

  assert_contains "$out" 'current protected-path probe: GRANTED' \
    'successful behavioral Full Disk Access probe was lost'
  assert_contains "$out" 'requirement=REQUIRED FOR COMPUTER USE status=GRANTED' \
    'stored no-mistakes Screen Recording grant was not reported'
  assert_contains "$out" 'requirement=REQUIRED FOR COMPUTER USE status=MISSING' \
    'stored no-mistakes Accessibility denial was not reported'
  assert_contains "$out" 'com.mitchellh.ghostty -> com.apple.systemevents: GRANTED' \
    'stored Ghostty-to-System Events Automation relationship was not reported'
  pass 'readable TCC rows are advisory statuses while behavior stays authoritative'
}

test_exact_settings_urls_and_no_other_mutation() {
  local world pane expected log mutation_log out
  world=$(make_world panes)
  log="$world/open.log"
  mutation_log="$world/mutation.log"
  : > "$log"

  while IFS='|' read -r pane expected; do
    out=$(FM_FAKE_OPEN_LOG="$log" FM_FAKE_MUTATION_LOG="$mutation_log" \
      run_report "$world" --open "$pane")
    assert_contains "$out" "Opened $expected; the human must make the grant." \
      "$pane did not report the human approval boundary"
  done <<'EOF'
full-disk-access|x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
automation|x-apple.systempreferences:com.apple.preference.security?Privacy_Automation
screen-recording|x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture
accessibility|x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
EOF

  [ "$(wc -l < "$log" | tr -d ' ')" -eq 4 ] || fail 'unexpected number of open calls'
  grep -Fx 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles' "$log" >/dev/null \
    || fail 'Full Disk Access URL drifted'
  grep -Fx 'x-apple.systempreferences:com.apple.preference.security?Privacy_Automation' "$log" >/dev/null \
    || fail 'Automation URL drifted'
  grep -Fx 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' "$log" >/dev/null \
    || fail 'Screen Recording URL drifted'
  grep -Fx 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' "$log" >/dev/null \
    || fail 'Accessibility URL drifted'
  [ ! -e "$mutation_log" ] || fail 'the helper invoked tccutil'
  pass 'only the exact requested System Settings panes are opened'
}

test_non_macos_refuses() {
  local world out code
  world=$(make_world non-macos)
  set +e
  out=$(FM_FAKE_UNAME=Linux run_report "$world" 2>&1)
  code=$?
  set -e

  [ "$code" -eq 1 ] || fail "non-macOS exit was $code instead of 1"
  assert_contains "$out" 'supports macOS only' 'non-macOS refusal was unclear'
  pass 'non-macOS hosts fail clearly without probing or opening settings'
}

test_missing_probe_is_honest
test_readable_database_reports_stored_rows
test_exact_settings_urls_and_no_other_mutation
test_non_macos_refuses
