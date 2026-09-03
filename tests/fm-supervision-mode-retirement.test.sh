#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Regression guard for the retired alternate supervision mode.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot_into TMP_ROOT fm-supervision-mode-retirement
RENDER="$ROOT/bin/fm-supervision-instructions.sh"
WATCH="$ROOT/bin/fm-watch.sh"
FINDINGS="$TMP_ROOT/retired-surface-findings"

assert_removed_paths() {
  local path
  for path in \
    .agents/skills/afk \
    bin/fm-afk-launch.sh \
    bin/fm-afk-start.sh \
    bin/fm-supervise-daemon.sh \
    docs/wedge-alarm.md \
    docs/examples/wedge-alarm \
    docs/postmortems/away-mode-injection-wedge.md \
    tests/fm-afk-inject-e2e.test.sh \
    tests/fm-afk-inject-herdr-e2e.test.sh \
    tests/fm-afk-launch.test.sh \
    tests/fm-afk-reap-wake-e2e.test.sh \
    tests/fm-daemon.test.sh \
    tests/fm-wake-daemon-lifecycle-e2e.test.sh; do
    [ ! -e "$ROOT/$path" ] && [ ! -L "$ROOT/$path" ] \
      || fail "retired supervision path still exists: $path"
  done
  pass "retired skill, launchers, daemon, documentation, and dedicated suites are absent"
}

assert_no_supported_surface_references() {
  local path pattern
  pattern='(/afk|away[- ]mode|(^|[^[:alnum:]_])afk([^[:alnum:]_]|$)|subsuper|fm-afk|fm-supervise-daemon|[.]afk|WEDGE_ALARM|wedge-alarm|display notification)'
  : > "$FINDINGS"
  git -C "$ROOT" ls-files | while IFS= read -r path; do
    [ -f "$ROOT/$path" ] || continue
    [ "$path" = "tests/fm-supervision-mode-retirement.test.sh" ] && continue
    case "$path" in
      tests/fixtures/*) continue ;;
    esac
    LC_ALL=C grep -IEni "$pattern" "$ROOT/$path" \
      | sed "s#^#$path:#" >> "$FINDINGS" || true
  done
  [ ! -s "$FINDINGS" ] \
    || fail "retired supervision references remain outside the regression guard:\n$(cat "$FINDINGS")"
  pass "tracked runtime, package, documentation, and test surfaces contain no retired route or notification path"
}

assert_stale_artifacts_cannot_change_supervision() {
  local home out status phrase skill
  home="$TMP_ROOT/home"
  mkdir -p "$home/state" "$home/config"
  : > "$home/state/.afk"
  : > "$home/state/.subsuper-escalations"

  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_contains "$out" "Mode: Pi extension persistent background-wake cycle" \
    "normal Pi watcher protocol was not rendered"
  assert_contains "$out" "fm_watch_arm_pi" "normal Pi watcher arm route was not rendered"
  assert_not_contains "$out" "Away mode" "stale artifacts changed the rendered supervision mode"

  status=0
  FM_HOME="$home" "$RENDER" --harness pi --afk 1 >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "retired --afk renderer option"

  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; ! declare -F afk_present >/dev/null' _ "$WATCH" \
    || fail "watcher still exposes an alternate-mode predicate"

  for phrase in "going to bed" "I'm away" "back later"; do
    for skill in "$ROOT"/.agents/skills/*/SKILL.md; do
      [ -f "$skill" ] || continue
      if grep -Fi "$phrase" "$skill" >/dev/null; then
        fail "ordinary phrase '$phrase' still appears in skill routing metadata: $skill"
      fi
    done
  done
  pass "stale artifacts and ordinary absence phrases cannot select another supervision mode"
}

assert_removed_paths
assert_no_supported_surface_references
assert_stale_artifacts_cannot_change_supervision
