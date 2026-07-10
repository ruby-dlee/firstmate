#!/usr/bin/env bash
# Tests for fm-spawn.sh's per-agent chrome-devtools-axi browser isolation.
#
# The tests use fake tmux/lsof/npm/chrome-devtools-axi shims so they assert the
# exact launch and teardown contracts without launching a real browser.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-browser-axi-isolation)
export FM_BACKEND=tmux

make_browser_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
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
  capture-pane) cat "${FM_FAKE_TMUX_CAPTURE:-/dev/null}"; exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = prefix ] && [ "${2:-}" = -g ]; then
  printf '%s\n' "$FM_FAKE_NPM_PREFIX"
  exit 0
fi
exit 1
SH
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf 'cmd=%s session=%s port=%s mcp=%s auto=%s browser=%s userdir=%s\n' \
  "${1:-}" \
  "${CHROME_DEVTOOLS_AXI_SESSION:-}" \
  "${CHROME_DEVTOOLS_AXI_PORT:-}" \
  "${CHROME_DEVTOOLS_AXI_MCP_PATH:-}" \
  "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT:-}" \
  "${CHROME_DEVTOOLS_AXI_BROWSER_URL:-}" \
  "${CHROME_DEVTOOLS_AXI_USER_DATA_DIR:-}" >> "$FM_FAKE_AXI_LOG"
[ "${1:-}" = stop ] || exit 2
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/lsof" "$fakebin/npm" "$fakebin/chrome-devtools-axi"
  printf '%s\n' "$fakebin"
}

make_spawn_world() {
  local name=$1 w fakebin npm_prefix mcp
  w="$TMP_ROOT/$name"
  fakebin=$(make_browser_fakebin "$w")
  npm_prefix="$w/npm-global"
  mcp="$npm_prefix/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
  mkdir -p "$(dirname "$mcp")" "$w/home/state" "$w/home/data" "$w/home/projects" "$w/user-home"
  printf 'mcp\n' > "$mcp"
  printf '%s\n%s\n%s\n%s\n' "$w" "$fakebin" "$npm_prefix" "$mcp"
}

spawn_task_capture() {
  local w=$1 fakebin=$2 npm_prefix=$3 id=$4 mode=${5:-persistent} proj wt launchlog out status
  proj="$w/project-$id"
  wt="$w/worktree-$id"
  launchlog="$w/launch-$id.log"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  mkdir -p "$w/home/data/$id"
  printf 'brief for %s\n' "$id" > "$w/home/data/$id/brief.md"
  : > "$launchlog"
  out=$(PATH="$fakebin:$BASE_PATH" HOME="$w/user-home" TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_NPM_PREFIX="$npm_prefix" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
    FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_BROWSER_AXI_PROFILE_MODE="$mode" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1)
  status=$?
  expect_code 0 "$status" "spawn $id should succeed: $out"
  printf '%s\n' "$launchlog"
}

meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

assert_port_in_spawn_range() {
  local port=$1 label=$2
  case "$port" in
    ''|*[!0-9]*) fail "$label: port is not numeric: $port" ;;
  esac
  [ "$port" -ge 19000 ] && [ "$port" -le 20999 ] || fail "$label: port $port is outside 19000..20999"
}

test_port_allocator_degrades_when_probe_tools_are_missing() {
  local w no_probe err out status
  w="$TMP_ROOT/no-probe"
  no_probe="$w/path"
  err="$w/err.log"
  mkdir -p "$no_probe"

  eval "$(sed -n '/^browser_axi_port_is_free()/,/^browser_axi_profile_mode()/p' "$ROOT/bin/fm-spawn.sh" | sed '$d')"
  out=$(PATH="$no_probe" browser_axi_alloc_port fm-no-probe-z9 2>"$err")
  status=$?

  expect_code 0 "$status" "port allocator should not fail when lsof and nc are missing"
  [ -z "$out" ] || fail "port allocator should leave explicit port unset without probe tools, got: $out"
  assert_contains "$(cat "$err")" "warning: cannot probe chrome-devtools-axi ports without lsof or nc" \
    "port allocator did not warn about missing probe tools"
  pass "port allocator degrades to AXI's fallback when probe tools are missing"
}

test_persistent_spawn_wires_axi_env_and_meta() {
  local w fakebin npm_prefix mcp launchlog launch meta session port profile
  {
    IFS= read -r w
    IFS= read -r fakebin
    IFS= read -r npm_prefix
    IFS= read -r mcp
  } <<EOF
$(make_spawn_world persistent)
EOF
  launchlog=$(spawn_task_capture "$w" "$fakebin" "$npm_prefix" browser-persist-z1)
  launch=$(tail -n 1 "$launchlog")
  meta="$w/home/state/browser-persist-z1.meta"
  session=$(meta_field "$meta" browser_axi_session)
  port=$(meta_field "$meta" browser_axi_port)
  profile=$(meta_field "$meta" browser_axi_user_data_dir)

  [ -n "$session" ] || fail "persistent: meta missing browser_axi_session"
  assert_port_in_spawn_range "$port" persistent
  [ "$(meta_field "$meta" browser_axi_profile_mode)" = persistent ] || fail "persistent: profile mode not recorded"
  [ "$profile" = "$w/user-home/.fm-browser-profiles/$session" ] || fail "persistent: profile path not keyed to the session"
  [ "$(meta_field "$meta" browser_axi_mcp_path)" = "$mcp" ] || fail "persistent: MCP path not recorded from npm prefix"

  assert_contains "$launch" "env -u CHROME_DEVTOOLS_AXI_AUTO_CONNECT -u CHROME_DEVTOOLS_AXI_BROWSER_URL -u CHROME_DEVTOOLS_AXI_USER_DATA_DIR -u CHROME_DEVTOOLS_AXI_MCP_PATH" \
    "persistent: launch does not sanitize ambient AXI env"
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_SESSION='$session'" "persistent: launch missing AXI session"
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_PORT='$port'" "persistent: launch missing AXI port"
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_USER_DATA_DIR='$profile'" "persistent: launch missing per-task profile"
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_MCP_PATH='$mcp'" "persistent: launch missing MCP path"
  assert_not_contains "$profile" "Library/Application Support/Google/Chrome" "persistent: profile points at real Chrome"
  assert_not_contains "$profile" ".codex/chrome" "persistent: profile points at Codex native Chrome state"
  pass "persistent spawn wires isolated chrome-devtools-axi env and records metadata"
}

test_distinct_tasks_get_distinct_axi_identities() {
  local w fakebin npm_prefix mcp log_a log_b meta_a meta_b session_a session_b port_a port_b profile_a profile_b
  {
    IFS= read -r w
    IFS= read -r fakebin
    IFS= read -r npm_prefix
    IFS= read -r mcp
  } <<EOF
$(make_spawn_world distinct)
EOF
  log_a=$(spawn_task_capture "$w" "$fakebin" "$npm_prefix" browser-a-z1)
  log_b=$(spawn_task_capture "$w" "$fakebin" "$npm_prefix" browser-b-z2)
  [ -s "$log_a" ] || fail "distinct: first launch log missing"
  [ -s "$log_b" ] || fail "distinct: second launch log missing"
  meta_a="$w/home/state/browser-a-z1.meta"
  meta_b="$w/home/state/browser-b-z2.meta"
  session_a=$(meta_field "$meta_a" browser_axi_session)
  session_b=$(meta_field "$meta_b" browser_axi_session)
  port_a=$(meta_field "$meta_a" browser_axi_port)
  port_b=$(meta_field "$meta_b" browser_axi_port)
  profile_a=$(meta_field "$meta_a" browser_axi_user_data_dir)
  profile_b=$(meta_field "$meta_b" browser_axi_user_data_dir)

  [ "$session_a" != "$session_b" ] || fail "distinct: sessions are shared"
  [ "$profile_a" != "$profile_b" ] || fail "distinct: persistent profiles are shared"
  [ "$port_a" != "$port_b" ] || fail "distinct: explicit AXI ports are shared"
  [ "$(meta_field "$meta_a" browser_axi_mcp_path)" = "$mcp" ] || fail "distinct: first MCP path missing"
  [ "$(meta_field "$meta_b" browser_axi_mcp_path)" = "$mcp" ] || fail "distinct: second MCP path missing"
  pass "distinct task ids receive distinct AXI sessions, ports, and browser profiles"
}

test_ephemeral_spawn_omits_user_data_dir() {
  local w fakebin npm_prefix mcp launchlog launch meta session port
  {
    IFS= read -r w
    IFS= read -r fakebin
    IFS= read -r npm_prefix
    IFS= read -r mcp
  } <<EOF
$(make_spawn_world ephemeral)
EOF
  launchlog=$(spawn_task_capture "$w" "$fakebin" "$npm_prefix" browser-ephemeral-z3 ephemeral)
  launch=$(tail -n 1 "$launchlog")
  meta="$w/home/state/browser-ephemeral-z3.meta"
  session=$(meta_field "$meta" browser_axi_session)
  port=$(meta_field "$meta" browser_axi_port)

  [ -n "$session" ] || fail "ephemeral: meta missing browser_axi_session"
  assert_port_in_spawn_range "$port" ephemeral
  [ "$(meta_field "$meta" browser_axi_profile_mode)" = ephemeral ] || fail "ephemeral: profile mode not recorded"
  [ -z "$(meta_field "$meta" browser_axi_user_data_dir)" ] || fail "ephemeral: meta should not record a persistent profile"
  assert_contains "$launch" "-u CHROME_DEVTOOLS_AXI_USER_DATA_DIR" "ephemeral: launch does not clear ambient profile"
  assert_not_contains "$launch" "CHROME_DEVTOOLS_AXI_USER_DATA_DIR='$w/user-home" "ephemeral: launch still sets a persistent profile"
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_SESSION='$session'" "ephemeral: launch missing AXI session"
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_PORT='$port'" "ephemeral: launch missing AXI port"
  assert_contains "$launch" "CHROME_DEVTOOLS_AXI_MCP_PATH='$mcp'" "ephemeral: launch missing MCP path"
  pass "ephemeral spawn keeps the isolated AXI session and omits the persistent browser profile"
}

test_teardown_stops_recorded_axi_bridge_and_removes_profile() {
  local w fakebin npm_prefix mcp state id meta log profile out status
  {
    IFS= read -r w
    IFS= read -r fakebin
    IFS= read -r npm_prefix
    IFS= read -r mcp
  } <<EOF
$(make_spawn_world teardown)
EOF
  state="$w/home/state"
  id='browser-teardown-z4'
  log="$w/axi-stop.log"
  meta="$state/$id.meta"
  profile="$w/user-home/.fm-browser-profiles/fm-test-$id"
  : > "$log"
  mkdir -p "$state" "$profile/Default"
  fm_write_meta "$meta" \
    "window=firstmate:fm-$id" \
    "worktree=$w/missing-worktree" \
    "project=$w/missing-project" \
    "harness=codex" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=$w/tasktmp" \
    "browser_axi_session=fm-test-$id" \
    "browser_axi_port=19399" \
    "browser_axi_profile_mode=persistent" \
    "browser_axi_user_data_dir=$profile" \
    "browser_axi_mcp_path=$mcp"

  out=$(PATH="$fakebin:$BASE_PATH" HOME="$w/user-home" FM_FAKE_AXI_LOG="$log" \
    FM_FAKE_TMUX_CAPTURE="$w/capture" FM_FAKE_NPM_PREFIX="$npm_prefix" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$w/home/data" \
    FM_CONFIG_OVERRIDE="$w/home/config" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should succeed: $out"
  assert_contains "$(cat "$log")" "cmd=stop session=fm-test-$id port=19399 mcp=$mcp auto= browser= userdir=" \
    "teardown did not stop AXI with the recorded isolated session and sanitized env"
  [ ! -e "$profile" ] || fail "teardown: persistent browser profile was not removed"
  [ ! -e "$meta" ] || fail "teardown: meta was not removed"
  pass "teardown stops the recorded chrome-devtools-axi bridge and removes its persistent profile"
}

test_port_allocator_degrades_when_probe_tools_are_missing
test_persistent_spawn_wires_axi_env_and_meta
test_distinct_tasks_get_distinct_axi_identities
test_ephemeral_spawn_omits_user_data_dir
test_teardown_stops_recorded_axi_bridge_and_removes_profile
