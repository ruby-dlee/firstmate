#!/usr/bin/env bash
# Behavior tests for direct per-account usage selection and Herdr hook setup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECTOR="$ROOT/bin/fm-account-directory.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-directory-tests)
ACCOUNT_ROOT="$TMP_ROOT/accounts"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
QUOTA_LOG="$TMP_ROOT/quota.log"
HERDR_LOG="$TMP_ROOT/herdr.log"

mkdir -p "$ACCOUNT_ROOT/codex" "$ACCOUNT_ROOT/claude"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --provider ] && [ "${2:-}" = codex ] && [ "${3:-}" = --json ] || exit 64
account=${CODEX_HOME##*/}
cache_file=$XDG_CACHE_HOME/quota-axi/quotas.json
[ "$XDG_CACHE_HOME" = "$CODEX_HOME/.agent-fleet-quota-cache" ] || exit 65
[ ! -e "$cache_file" ] || exit 66
case "${QUOTA_AXI_HOSTILE+x}${AGENT_FLEET_HOSTILE+x}${XDG_CONFIG_HOME+x}" in
  '') ;;
  *) exit 67 ;;
esac
printf '%s\t%s\n' "$CODEX_HOME" "$XDG_CACHE_HOME" >> "$FM_FAKE_QUOTA_LOG"
remaining=$(cat "$CODEX_HOME/test-remaining")
mkdir -p "$(dirname "$cache_file")"
printf '{"cached":true}\n' > "$cache_file"
if [ "$remaining" = hang ]; then
  sleep 30
  exit 0
fi
if [ "$remaining" = none ]; then
  printf '%s\n' '{"providers":[{"provider":"codex","state":{"status":"auth_required"},"windows":[]}]}'
  exit 1
fi
five=${remaining%%,*}
week=${remaining#*,}
cat <<JSON
{"providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[
{"id":"five_hour","kind":"session","percentRemaining":$five},
{"id":"weekly","kind":"weekly","percentRemaining":$week},
{"id":"model:test:5h","kind":"model","percentRemaining":100}
]}]}
JSON
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = integration ] && [ "${2:-}" = install ] || exit 64
case "${3:-}" in
  codex)
    [ -n "${CODEX_HOME:-}" ] || exit 65
    printf 'codex\t%s\n' "$CODEX_HOME" >> "$FM_FAKE_HERDR_LOG"
    printf '#!/usr/bin/env bash\n' > "$CODEX_HOME/herdr-agent-state.sh"
    ;;
  claude)
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] || exit 66
    printf 'claude\t%s\n' "$CLAUDE_CONFIG_DIR" >> "$FM_FAKE_HERDR_LOG"
    mkdir -p "$CLAUDE_CONFIG_DIR/hooks"
    printf '#!/usr/bin/env bash\n' > "$CLAUDE_CONFIG_DIR/hooks/herdr-agent-state.sh"
    ;;
  *) exit 67 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

run_selector() {
  FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
    FM_ACCOUNT_DIRECTORY_ROOT="$ACCOUNT_ROOT" \
    FM_ACCOUNT_DIRECTORY_QUOTA_AXI="$FAKEBIN/quota-axi" \
    FM_ACCOUNT_DIRECTORY_HERDR="$FAKEBIN/herdr" \
    FM_FAKE_QUOTA_LOG="$QUOTA_LOG" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    "$SELECTOR" "$@"
}

set_remaining() {
  local account=$1 remaining=$2
  mkdir -p "$ACCOUNT_ROOT/codex/$account/.agent-fleet-quota-cache/quota-axi"
  printf '%s\n' "$remaining" > "$ACCOUNT_ROOT/codex/$account/test-remaining"
  printf '{"stale":true}\n' > "$ACCOUNT_ROOT/codex/$account/.agent-fleet-quota-cache/quota-axi/quotas.json"
}

reset_accounts() {
  rm -rf "$ACCOUNT_ROOT/codex" "$ACCOUNT_ROOT/claude"
  mkdir -p "$ACCOUNT_ROOT/codex" "$ACCOUNT_ROOT/claude"
  : > "$QUOTA_LOG"
  : > "$HERDR_LOG"
}

test_codex_picks_highest_fresh_minimum_and_skips_no_window() {
  local out err
  reset_accounts
  set_remaining 1 80,40
  set_remaining 2 none
  set_remaining 3 90,75
  out=$(QUOTA_AXI_HOSTILE=1 AGENT_FLEET_HOSTILE=1 XDG_CONFIG_HOME=/hostile \
    run_selector select codex 2>"$TMP_ROOT/codex-select.err")
  err=$(cat "$TMP_ROOT/codex-select.err")
  [ "$out" = "$ACCOUNT_ROOT/codex/3" ] || fail "Codex did not choose the account with the highest minimum remaining usage: $out"
  assert_contains "$err" "codex account $ACCOUNT_ROOT/codex/2 skipped: no freshly readable usage window" \
    "Codex no-window account was not visibly skipped"
  assert_contains "$err" "selected codex account $ACCOUNT_ROOT/codex/3 with fresh remaining score=75" \
    "Codex selection did not report its fresh score"
  [ "$(wc -l < "$QUOTA_LOG" | tr -d ' ')" = 3 ] || fail "Codex selection did not read every discovered account"
  pass "Codex selects the highest fresh general-window minimum and skips only unreadable accounts"
}

test_codex_rechecks_health_on_every_selection() {
  local first second calls
  reset_accounts
  set_remaining 1 30,20
  set_remaining 2 none
  first=$(run_selector select codex 2>"$TMP_ROOT/recheck-first.err")
  [ "$first" = "$ACCOUNT_ROOT/codex/1" ] || fail "initial Codex selection ignored the only healthy account"

  set_remaining 2 100,100
  second=$(run_selector select codex 2>"$TMP_ROOT/recheck-second.err")
  [ "$second" = "$ACCOUNT_ROOT/codex/2" ] || fail "freshly re-authenticated Codex account stayed cached as unhealthy"
  calls=$(grep -c "^$ACCOUNT_ROOT/codex/2"$'\t' "$QUOTA_LOG" || true)
  [ "$calls" = 2 ] || fail "Codex account health was not re-read on both selections"
  pass "Codex health is read fresh at selection time so a newly authenticated account is immediately eligible"
}

test_codex_fails_when_no_account_has_a_fresh_window() {
  local out status
  reset_accounts
  set_remaining 1 none
  set_remaining 2 none
  out=$(run_selector select codex 2>&1)
  status=$?
  expect_code 1 "$status" "Codex selection with no healthy accounts should fail closed"
  assert_contains "$out" "no healthy Codex account has a freshly readable usage window" \
    "Codex all-unhealthy failure was not actionable"
  pass "Codex refuses selection when every discovered account lacks fresh readable usage"
}

test_codex_timeout_skips_wedged_account() {
  local out err
  reset_accounts
  set_remaining 1 hang
  set_remaining 2 90,85
  out=$(FM_ACCOUNT_DIRECTORY_QUOTA_TIMEOUT_SECONDS=1 \
    run_selector select codex 2>"$TMP_ROOT/codex-timeout.err")
  err=$(cat "$TMP_ROOT/codex-timeout.err")
  [ "$out" = "$ACCOUNT_ROOT/codex/2" ] || fail "wedged Codex account prevented selection of a later healthy account: $out"
  assert_contains "$err" "codex account $ACCOUNT_ROOT/codex/1 skipped: quota read timed out after 1s" \
    "Codex timeout was not classified as an unreadable account"
  pass "Codex bounds each usage read and continues to later healthy accounts"
}

test_claude_uses_stable_first_without_treating_usage_as_health() {
  local out err
  reset_accounts
  mkdir -p "$ACCOUNT_ROOT/claude/2" "$ACCOUNT_ROOT/claude/1"
  out=$(run_selector select claude 2>"$TMP_ROOT/claude-select.err")
  err=$(cat "$TMP_ROOT/claude-select.err")
  [ "$out" = "$ACCOUNT_ROOT/claude/1" ] || fail "Claude fallback did not use stable bytewise directory order: $out"
  assert_contains "$err" "CLAUDE USAGE UNREADABLE" "Claude fallback did not carry the required obvious warning"
  assert_contains "$err" "config-dir-specific macOS Keychain credential" \
    "Claude fallback did not explain the keychain/quota-read gap"
  [ ! -s "$QUOTA_LOG" ] || fail "Claude fallback called quota-axi even though per-directory usage is known unreadable"
  pass "Claude deterministically selects the first directory and explains why usage is not a health signal"
}

test_default_root_uses_passwd_home_not_ambient_home() {
  local passwd_home hostile_home expected out
  passwd_home="$TMP_ROOT/passwd-home"
  hostile_home="$TMP_ROOT/hostile-home"
  expected="$passwd_home/.local/share/agent-fleet/accounts/claude/1"
  mkdir -p "$expected" "$hostile_home/.local/share/agent-fleet/accounts/claude/0"
  out=$(HOME="$hostile_home" \
    FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
    FM_ACCOUNT_DIRECTORY_PASSWD_HOME="$passwd_home" \
    "$SELECTOR" select claude 2>"$TMP_ROOT/passwd-home.err")
  [ "$out" = "$expected" ] || fail "ambient HOME redirected account discovery away from the passwd home: $out"
  pass "default account discovery ignores ambient HOME and stays under the passwd home"
}

test_prepare_installs_and_verifies_per_account_herdr_hooks() {
  local codex_home claude_home
  reset_accounts
  set_remaining 1 90,80
  mkdir -p "$ACCOUNT_ROOT/claude/1"

  codex_home=$(run_selector prepare codex 2>"$TMP_ROOT/prepare-codex.err")
  claude_home=$(run_selector prepare claude 2>"$TMP_ROOT/prepare-claude.err")
  [ -f "$codex_home/herdr-agent-state.sh" ] || fail "Codex Herdr hook was not installed in the selected profile home"
  [ -f "$claude_home/hooks/herdr-agent-state.sh" ] || fail "Claude Herdr hook was not installed in the selected profile home"
  assert_grep $'codex\t'"$ACCOUNT_ROOT/codex/1" "$HERDR_LOG" "Herdr installer did not receive CODEX_HOME"
  assert_grep $'claude\t'"$ACCOUNT_ROOT/claude/1" "$HERDR_LOG" "Herdr installer did not receive CLAUDE_CONFIG_DIR"
  pass "prepare uses Herdr's own installer and verifies each selected profile hook"
}

make_spawn_fakebin() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for argument in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$argument" >> "$FM_FAKE_LAUNCH_LOG"
      fi
      prev=$argument
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/forbidden-agent-fleet" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$FM_FAKE_AGENT_FLEET_LOG"
exit 99
SH
  chmod +x "$fakebin/forbidden-agent-fleet"
}

run_direct_spawn() {
  local home=$1 worktree=$2 launch_log=$3
  shift 3
  : > "$launch_log"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launch_log" PATH="$FAKEBIN:$PATH" \
    FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
    FM_ACCOUNT_DIRECTORY_ROOT="$ACCOUNT_ROOT" \
    FM_ACCOUNT_DIRECTORY_QUOTA_AXI="$FAKEBIN/quota-axi" \
    FM_ACCOUNT_DIRECTORY_HERDR="$FAKEBIN/herdr" \
    FM_FAKE_QUOTA_LOG="$QUOTA_LOG" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_AGENT_FLEET_BIN="$FAKEBIN/forbidden-agent-fleet" \
    FM_FAKE_AGENT_FLEET_LOG="$TMP_ROOT/agent-fleet.log" \
    "$ROOT/bin/fm-spawn.sh" "$@"
}

make_spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir home project worktree launch_log
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  launch_log="$case_dir/launch.log"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  printf '%s\n' "$home|$project|$worktree|$launch_log"
}

read_spawn_case() {
  IFS='|' read -r SPAWN_HOME SPAWN_PROJECT SPAWN_WORKTREE SPAWN_LAUNCH_LOG <<EOF
$1
EOF
}

test_spawn_uses_direct_codex_home_without_agent_fleet() {
  local record id out launch meta
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 30,20
  set_remaining 2 100,95
  id=direct-codex-z1
  record=$(make_spawn_case direct-codex codex "$id")
  read_spawn_case "$record"
  printf '%s\n' enforce > "$SPAWN_HOME/config/account-routing-mode"

  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  meta=$SPAWN_HOME/state/$id.meta
  assert_contains "$out" "selected direct codex account home $ACCOUNT_ROOT/codex/2" \
    "spawn did not report its direct Codex account"
  assert_contains "$launch" "CODEX_HOME='$ACCOUNT_ROOT/codex/2' codex" \
    "spawn did not scope Codex to the selected account home"
  assert_grep "account_home=$ACCOUNT_ROOT/codex/2" "$meta" "spawn metadata omitted the selected account home"
  if grep -q '^account_profile=' "$meta"; then fail "new direct spawn wrote legacy managed profile metadata"; fi
  if grep -q '^account_pool=' "$meta"; then fail "new direct spawn wrote legacy managed pool metadata"; fi
  [ ! -s "$TMP_ROOT/agent-fleet.log" ] || fail "new direct spawn invoked Agent Fleet"
  pass "new enforced Codex spawn uses CODEX_HOME and never enters Agent Fleet"
}

test_spawn_uses_direct_claude_fallback_and_hook() {
  local record id out launch meta
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  mkdir -p "$ACCOUNT_ROOT/claude/2" "$ACCOUNT_ROOT/claude/1"
  id=direct-claude-z2
  record=$(make_spawn_case direct-claude claude "$id")
  read_spawn_case "$record"

  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool legacy-claude-pool 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  meta=$SPAWN_HOME/state/$id.meta
  assert_contains "$out" "CLAUDE USAGE UNREADABLE" "spawn hid the required Claude quota-read warning"
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$ACCOUNT_ROOT/claude/1' claude" \
    "spawn did not scope Claude to the deterministic first account home"
  assert_grep "account_home=$ACCOUNT_ROOT/claude/1" "$meta" "Claude spawn metadata omitted account_home"
  [ -f "$ACCOUNT_ROOT/claude/1/hooks/herdr-agent-state.sh" ] || fail "Claude spawn did not install its per-account Herdr hook"
  [ ! -s "$TMP_ROOT/agent-fleet.log" ] || fail "new direct Claude spawn invoked Agent Fleet"
  pass "new account-flagged Claude spawn uses deterministic CLAUDE_CONFIG_DIR with an explicit warning"
}

test_observe_spawn_uses_direct_directory_without_agent_fleet() {
  local record id out launch meta
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 75,70
  id=direct-observe-z3
  record=$(make_spawn_case direct-observe codex "$id")
  read_spawn_case "$record"
  printf '%s\n' observe > "$SPAWN_HOME/config/account-routing-mode"

  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  meta=$SPAWN_HOME/state/$id.meta
  assert_contains "$launch" "CODEX_HOME='$ACCOUNT_ROOT/codex/1' codex" \
    "observe launch did not use direct Codex selection"
  assert_grep "account_home=$ACCOUNT_ROOT/codex/1" "$meta" "observe metadata omitted the direct account home"
  [ ! -s "$TMP_ROOT/agent-fleet.log" ] || fail "observe launch invoked Agent Fleet"
  assert_not_contains "$out" "fm-account-routing: observe" "observe launch entered the legacy dry-run selector"
  pass "observe mode uses direct account-directory routing without Agent Fleet"
}

test_stale_secondmate_without_direct_cutover_is_refused() {
  local primary home id out status
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 80,80
  id=stale-secondmate-z4
  primary="$TMP_ROOT/stale-primary"
  home="$TMP_ROOT/stale-secondmate"
  mkdir -p "$primary/data/$id" "$primary/projects" "$primary/state" "$primary/config"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' codex > "$primary/config/crew-harness"
  printf '%s\n' enforce > "$primary/config/account-routing-mode"
  touch "$primary/state/.last-watcher-beat"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '%s\n' '# Firstmate' > "$home/AGENTS.md"
  printf '%s\n' charter > "$home/data/charter.md"
  printf '%s\n' 'fm_account_resolve_mode() {' '  :' '}' > "$home/bin/fm-account-routing-lib.sh"
  printf '%s\n' \
    'ACCOUNT_EFFECTIVE_MODE=$(fm_account_resolve_mode "$CONFIG" 0 0)' \
    '"$SCRIPT_DIR/fm-account-directory.sh" prepare "$HARNESS"' \
    > "$home/bin/fm-spawn.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$home/bin/fm-account-directory.sh"
  chmod +x "$home/bin/fm-account-directory.sh"

  if out=$(run_direct_spawn "$primary" "$home" "$TMP_ROOT/stale-secondmate-launch.log" \
    "$id" "$home" --harness codex --secondmate 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "stale enforced secondmate launched without the direct account-directory cutover"
  assert_contains "$out" "lacks direct account-directory routing support" \
    "stale secondmate refusal did not identify the missing direct cutover"
  [ ! -s "$TMP_ROOT/stale-secondmate-launch.log" ] || fail "stale secondmate reached provider launch"
  pass "enforced secondmates require the direct account-directory cutover after a skipped sync"
}

test_routing_off_keeps_default_provider_launch() {
  local record id out launch meta
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 100,100
  id=direct-off-z3
  record=$(make_spawn_case direct-off codex "$id")
  read_spawn_case "$record"
  printf '%s\n' off > "$SPAWN_HOME/config/account-routing-mode"

  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  meta=$SPAWN_HOME/state/$id.meta
  assert_contains "$out" "spawned $id harness=codex" "routing-off spawn failed"
  assert_not_contains "$launch" "CODEX_HOME=" "routing-off launch unexpectedly selected an account directory"
  if grep -q '^account_home=' "$meta"; then fail "routing-off metadata unexpectedly recorded an account home"; fi
  [ ! -s "$QUOTA_LOG" ] || fail "routing-off spawn read per-account quota"
  [ ! -s "$HERDR_LOG" ] || fail "routing-off spawn ran the Herdr profile installer"
  [ ! -s "$TMP_ROOT/agent-fleet.log" ] || fail "routing-off spawn invoked Agent Fleet"
  pass "routing off preserves the provider's default identity and performs no account selection"
}

make_spawn_fakebin "$FAKEBIN"

test_codex_picks_highest_fresh_minimum_and_skips_no_window
test_codex_rechecks_health_on_every_selection
test_codex_fails_when_no_account_has_a_fresh_window
test_codex_timeout_skips_wedged_account
test_claude_uses_stable_first_without_treating_usage_as_health
test_default_root_uses_passwd_home_not_ambient_home
test_prepare_installs_and_verifies_per_account_herdr_hooks
test_spawn_uses_direct_codex_home_without_agent_fleet
test_spawn_uses_direct_claude_fallback_and_hook
test_observe_spawn_uses_direct_directory_without_agent_fleet
test_stale_secondmate_without_direct_cutover_is_refused
test_routing_off_keeps_default_provider_launch

echo "# all fm-account-directory tests passed"
