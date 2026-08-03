#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. fm-lint.sh now pins one exact version and both
# gates resolve it, so command, file set, config, AND version all match.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The authoritative file set the one owner must run.
CANON='run_shellcheck_batches bin/*.sh bin/backends/*.sh tests/*.sh'
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

normalize_shellcheck_findings() {
  awk '
    $0 == "For more information:" { footer = 1; next }
    footer == 1 { footer = 0; next }
    NF { print }
  '
}

test_owner_exists_and_executable() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable so CI/gate can run it directly"
  pass "one-owner lint script exists and is executable"
}

test_owner_defines_canonical_set() {
  assert_grep "$CANON" "$LINT" "fm-lint.sh must run the canonical shellcheck file set"
  # It must not weaken CI: no severity downgrade and no blanket disable/exclude
  # that would hide findings CI fails on.
  assert_no_grep '--severity' "$LINT" "fm-lint.sh must not lower severity below the CI default"
  assert_no_grep '--exclude' "$LINT" "fm-lint.sh must not blanket-exclude checks CI enforces"
  [ "$(grep -Fc 'shellcheck --norc -x' "$LINT")" -eq 2 ] || fail "every lint batch must preserve source context and ignore ambient configuration"
  pass "fm-lint.sh is the sole authoritative definition at CI-default severity"
}

test_batches_every_input_at_the_shellcheck_boundary() {
  local tmp fakebin counts actual expected batch_size expected_batches rc i
  local -a inputs=()
  fm_test_tmproot_into tmp fm-lint-batches
  fakebin=$(fm_fakebin "$tmp")
  counts="$tmp/counts"
  actual="$tmp/actual"
  expected="$tmp/expected"
  batch_size=$(awk -F= '/^SHELLCHECK_BATCH_SIZE=/{print $2; exit}' "$LINT")
  expected_batches=$(((197 + batch_size - 1) / batch_size))

  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\nlicense: x\nwebsite: y\n'
  exit 0
fi
[ "${1:-}" = "--norc" ] || exit 97
[ "${2:-}" = "-x" ] || exit 98
shift 2
printf '%s\n' "$#" >> "$FM_LINT_COUNTS"
printf '%s\n' "$@" >> "$FM_LINT_INPUTS"
SH
  chmod +x "$fakebin/shellcheck"

  # 197 deliberately exceeds today's 186-file canonical set.
  for ((i = 1; i <= 197; i++)); do
    inputs+=("$tmp/input-$i.sh")
  done
  printf '%s\n' "${inputs[@]}" > "$expected"

  rc=0
  FM_LINT_COUNTS="$counts" FM_LINT_INPUTS="$actual" PATH="$fakebin:$PATH" \
    "$LINT" "${inputs[@]}" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh failed the 197-input batching fixture (exit $rc)"
  [ "$(wc -l < "$counts" | tr -d ' ')" -eq "$expected_batches" ] || fail "197 inputs were not split into $expected_batches ShellCheck processes"
  awk -v max="$batch_size" '$1 > max { exit 1 }' "$counts" || fail "a ShellCheck process exceeded the $batch_size-file cap"
  cmp -s "$expected" "$actual" || fail "batched lint did not pass every input exactly once and in order"

  # Positive control: the same boundary instrument must reject one unbatched
  # 197-file call, or its reassuring answer above would prove nothing.
  : > "$counts"
  : > "$actual"
  FM_LINT_COUNTS="$counts" FM_LINT_INPUTS="$actual" PATH="$fakebin:$PATH" \
    shellcheck --norc -x "${inputs[@]}"
  [ "$(wc -l < "$counts" | tr -d ' ')" -eq 1 ] || fail "positive control did not make one ShellCheck call"
  if awk -v max="$batch_size" '$1 > max { exit 1 }' "$counts"; then
    fail "batch-cap instrument accepted the unbatched 197-file positive control"
  fi
  pass "all 197 inputs reach ShellCheck exactly once in batches capped at $batch_size (positive control: 197 at once is rejected)"
}

test_ci_invokes_the_owner() {
  grep -Eq '^      - run: bin/fm-lint\.sh$' "$CI" || fail "CI lint job must invoke the one-owner script as a run step"
  # Guard against regression to an inline re-spelling of the command.
  assert_no_grep 'run: shellcheck' "$CI" "CI must call fm-lint.sh, not re-spell shellcheck inline"
  pass "CI lint job calls the one-owner script, not an inline command"
}

test_nomistakes_invokes_the_owner() {
  grep -Fqx "  lint: 'bin/fm-lint.sh && uv run --directory tools/agent-fleet --locked ruff check .'" "$NM" || fail "no-mistakes commands.lint must invoke the shell owner and locked Agent Fleet lint"
  pass "no-mistakes pre-push lint calls the shell owner and locked Agent Fleet lint"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_ci_installs_and_logs_the_pinned_version() {
  # CI must derive the version from the one owner (never hardcode a divergent
  # number) and log the resolved version as parity evidence.
  assert_grep "VERSION=\"\$(\"\$ROOT/bin/fm-lint.sh\" --required-version)\"" "$INSTALLER" "installer must read the version fm-lint.sh pins"
  [ "$(grep -Fc "bin/fm-install-shellcheck.sh \"\$RUNNER_TEMP/bin\"" "$CI")" -eq 2 ] || fail "both CI jobs must use the shared ShellCheck installer"
  assert_grep "ACTUAL_SHA256=\$(sha256sum" "$INSTALLER" "installer must calculate the ShellCheck archive checksum"
  assert_grep "[ \"\$ACTUAL_SHA256\" = \"\$SHA256\" ]" "$INSTALLER" "installer must verify the ShellCheck archive checksum"
  assert_grep "\"\$DESTINATION/shellcheck\" --version" "$INSTALLER" "installer must log the resolved ShellCheck version as evidence"
  pass "CI installs and logs the pinned ShellCheck version from the one owner"
}

test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  local tmp fakebin out rc
  fm_test_tmproot_into tmp fm-lint-ver
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\nlicense: x\nwebsite: y\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  fm_test_tmproot_into tmp fm-lint-bad
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  fm_test_tmproot_into tmp fm-lint-opts
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  fm_test_tmproot_into tmp fm-lint-good
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_batching_preserves_cross_batch_source_context() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): cross-batch source-context check"
    return
  fi
  local tmp caller library filler monolithic batched isolated monolithic_findings batched_findings
  local monolithic_rc batched_rc isolated_rc i
  local -a inputs=()
  fm_test_tmproot_into tmp fm-lint-sources
  mkdir -p "$tmp"
  caller="$tmp/caller.sh"
  library="$tmp/library.sh"
  cat > "$library" <<'SH'
#!/usr/bin/env bash
shared_value=ready
SH
  # shellcheck disable=SC2016 # Dollar expressions belong to the generated fixture.
  {
    printf '#!/usr/bin/env bash\n'
    printf '# shellcheck source=%s\n' "$library"
    printf '. "$SHARED_LIBRARY"\n'
    printf 'printf "%%s\\n" "$shared_value"\n'
  } > "$caller"
  inputs+=("$caller")
  for ((i = 1; i <= 9; i++)); do
    filler="$tmp/filler-$i.sh"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" ok\n' > "$filler"
    inputs+=("$filler")
  done
  # The sourced library is deliberately in the next batch.
  inputs+=("$library")

  monolithic_rc=0
  monolithic=$(shellcheck --norc "${inputs[@]}" 2>/dev/null) || monolithic_rc=$?
  batched_rc=0
  batched=$(SHARED_LIBRARY="$library" "$LINT" "${inputs[@]}" 2>/dev/null) || batched_rc=$?
  monolithic_findings=$(printf '%s\n' "$monolithic" | normalize_shellcheck_findings)
  batched_findings=$(printf '%s\n' "$batched" | normalize_shellcheck_findings)
  [ "$batched_rc" -eq "$monolithic_rc" ] || fail "batching lost source context across a batch boundary"
  if [ "$batched_findings" != "$monolithic_findings" ]; then
    diff -u <(printf '%s\n' "$monolithic_findings") <(printf '%s\n' "$batched_findings") >&2 || true
    fail "batching changed findings when a source and caller landed in different batches"
  fi

  # Positive control: the first batch alone and without external-source context
  # must report the missing source that batching is required to preserve.
  isolated_rc=0
  isolated=$(SHARED_LIBRARY="$library" shellcheck --norc "${inputs[@]:0:10}" 2>/dev/null) || isolated_rc=$?
  [ "$isolated_rc" -ne 0 ] || fail "source-context positive control unexpectedly passed"
  assert_contains "$isolated" "SC1091" "source-context positive control did not expose the cross-batch source"
  pass "batching preserves source context across batches (positive control: isolated batch reports SC1091)"
}

test_batching_preserves_findings_on_every_input() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): batched findings parity check"
    return
  fi
  local tmp file monolithic batched reduced monolithic_findings batched_findings reduced_findings
  local monolithic_rc batched_rc reduced_rc i
  local -a bad=()
  fm_test_tmproot_into tmp fm-lint-findings
  mkdir -p "$tmp"
  for ((i = 1; i <= 12; i++)); do
    file="$tmp/bad-$i.sh"
    cat > "$file" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
    bad+=("$file")
  done

  monolithic_rc=0
  monolithic=$(shellcheck --norc "${bad[@]}" 2>/dev/null) || monolithic_rc=$?
  batched_rc=0
  batched=$("$LINT" "${bad[@]}" 2>/dev/null) || batched_rc=$?
  monolithic_findings=$(printf '%s\n' "$monolithic" | normalize_shellcheck_findings)
  batched_findings=$(printf '%s\n' "$batched" | normalize_shellcheck_findings)
  [ "$monolithic_rc" -eq "$batched_rc" ] || fail "batched lint changed ShellCheck's finding exit status"
  if [ "$monolithic_findings" != "$batched_findings" ]; then
    diff -u <(printf '%s\n' "$monolithic_findings") <(printf '%s\n' "$batched_findings") >&2 || true
    fail "batched lint changed the findings reported for the same 12 inputs"
  fi
  [ "$(printf '%s\n' "$batched_findings" | grep -c 'SC1007')" -eq 12 ] || fail "batched lint did not report SC1007 for every one of 12 bad inputs"
  for file in "${bad[@]}"; do
    assert_contains "$batched" "$file" "batched lint omitted the finding for $file"
  done

  # Positive control: prove the output comparison sees a one-file coverage loss.
  reduced_rc=0
  reduced=$(shellcheck --norc "${bad[@]:0:11}" 2>/dev/null) || reduced_rc=$?
  reduced_findings=$(printf '%s\n' "$reduced" | normalize_shellcheck_findings)
  [ "$reduced_rc" -eq "$monolithic_rc" ] || fail "positive-control ShellCheck status unexpectedly changed"
  [ "$reduced_findings" != "$monolithic_findings" ] || fail "findings comparator could not detect one omitted input"
  pass "batching preserves every finding on every input (positive control: one omitted input differs)"
}

test_owner_exists_and_executable
test_owner_defines_canonical_set
test_batches_every_input_at_the_shellcheck_boundary
test_ci_invokes_the_owner
test_nomistakes_invokes_the_owner
test_pins_an_explicit_version
test_ci_installs_and_logs_the_pinned_version
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_batching_preserves_cross_batch_source_context
test_batching_preserves_findings_on_every_input
