#!/usr/bin/env bash
# Behavior tests for worktree dependency provisioning (bin/fm-provision-lib.sh)
# and its fm-spawn.sh hook.
#
# The installers are stubbed. These tests own the provisioning CONTRACT - what
# is detected, when an install is skipped, and what happens when it fails - not
# whether uv or npm work, which is their business and would make the suite need
# a network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-provision-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-provision)

# --- fixtures ---------------------------------------------------------------

# Stub installers that record every invocation to $FM_TEST_INSTALL_LOG and
# produce exactly the artifacts the real ones do, so the readiness probes are
# exercised for real. FM_TEST_UV_FAIL / FM_TEST_NPM_FAIL / FM_TEST_NPM_SLEEP
# steer the failure and hang cases.
make_installer_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/uv" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_INSTALL_LOG:-}" ] || printf 'uv %s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
case "${1:-}" in
  --version) printf 'uv 1.2.3 (testfake)\n'; exit 0 ;;
  venv)
    [ "${FM_TEST_UV_FAIL:-0}" != 1 ] || exit 3
    rm -rf .venv
    mkdir -p .venv/bin .venv/lib/python3.11/site-packages
    cat > .venv/bin/python <<'PY'
#!/usr/bin/env bash
case "${2:-}" in
  *sys.version_info*) printf '%s' "${FM_TEST_PYTHON_VERSION:-3.11.9}" ;;
  *) exec python3 "$@" ;;
esac
PY
    chmod +x .venv/bin/python
    exit 0
    ;;
  sync)
    [ "${FM_TEST_UV_FAIL:-0}" != 1 ] || exit 3
    if [ "${FM_TEST_REQUIRE_UV_DEFAULT_GROUPS:-0}" = 1 ]; then
      [ -z "${UV_NO_DEV:-}${UV_ONLY_DEV:-}${UV_NO_DEFAULT_GROUPS:-}${UV_NO_GROUP:-}${UV_ONLY_GROUP:-}" ] \
        || exit 9
    fi
    mkdir -p .venv/bin .venv/lib/python3.11/site-packages
    printf 'fake uv project\n' > .venv/lib/python3.11/site-packages/fake_uv_project.pth
    cat > .venv/bin/python <<'PY'
#!/usr/bin/env bash
case "${2:-}" in
  *sys.version_info*) printf '%s' "${FM_TEST_PYTHON_VERSION:-3.11.9}" ;;
  *) exec python3 "$@" ;;
esac
PY
    chmod +x .venv/bin/python
    exit 0
    ;;
  pip)
    case "${2:-}" in
      install)
        [ "${FM_TEST_UV_FAIL:-0}" != 1 ] || exit 3
        mkdir -p .venv/lib/python3.11/site-packages/pytest \
          .venv/lib/python3.11/site-packages/six-1.16.0.dist-info \
          .venv/lib/python3.11/site-packages/pytest-8.3.4.dist-info
        printf 'six module\n' > .venv/lib/python3.11/site-packages/six.py
        printf 'pytest package\n' > .venv/lib/python3.11/site-packages/pytest/__init__.py
        printf 'Name: six\nVersion: 1.16.0\n' > .venv/lib/python3.11/site-packages/six-1.16.0.dist-info/METADATA
        printf 'Name: pytest\nVersion: 8.3.4\n' > .venv/lib/python3.11/site-packages/pytest-8.3.4.dist-info/METADATA
        printf '#!/usr/bin/env bash\nexit 0\n' > .venv/bin/pytest
        chmod +x .venv/bin/pytest
        exit 0
        ;;
      check) [ -x .venv/bin/python ] || exit 1; exit 0 ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_INSTALL_LOG:-}" ] || printf 'npm %s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
case "${1:-}" in
  --version) printf '10.9.2\n'; exit 0 ;;
  ci)
    [ "${FM_TEST_NPM_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_NPM_SLEEP"
    [ "${FM_TEST_NPM_FAIL:-0}" != 1 ] || {
      mkdir -p node_modules/partial-package
      printf 'partial\n' > node_modules/partial-package/partial.txt
      printf 'npm ci exploded\n' >&2
      exit 7
    }
    mkdir -p node_modules/is-number
    printf '{"name":"is-number","version":"7.0.0"}\n' > node_modules/is-number/package.json
    printf 'module.exports = true\n' > node_modules/is-number/index.js
    case " $* " in
      *' --include=dev '*)
        mkdir -p node_modules/test-runner
        printf '{"name":"test-runner","version":"1.0.0"}\n' > node_modules/test-runner/package.json
        ;;
    esac
    printf '{}\n' > node_modules/.package-lock.json
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/pnpm" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_INSTALL_LOG:-}" ] || printf 'pnpm %s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
case "${1:-}" in
  --version) printf '9.0.0\n'; exit 0 ;;
  install)
    mkdir -p node_modules/is-number
    printf '{"name":"is-number","version":"7.0.0"}\n' > node_modules/is-number/package.json
    printf 'module.exports = true\n' > node_modules/is-number/index.js
    case " $* " in
      *' --prod=false '*)
        mkdir -p node_modules/test-runner
        printf '{"name":"test-runner","version":"1.0.0"}\n' > node_modules/test-runner/package.json
        ;;
    esac
    printf 'hoistPattern:\n' > node_modules/.modules.yaml
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  -p|--print) printf '%s' "${FM_TEST_NODE_VERSION:-20.20.2}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/uv" "$fakebin/npm" "$fakebin/pnpm" "$fakebin/node"
  printf '%s\n' "$fakebin"
}

# A python worktree, a js worktree, or both, with no git repo needed: the
# library operates on a directory.
make_worktree() {
  local dir=$1 shape=$2
  mkdir -p "$dir"
  case "$shape" in
    python|both)
      mkdir -p "$dir/svc"
      printf 'six==1.16.0\n' > "$dir/svc/requirements.txt"
      printf 'pytest==8.3.4\n' > "$dir/svc/requirements-test.txt"
      ;;
  esac
  case "$shape" in
    js|both)
      mkdir -p "$dir/web"
      printf '{"name":"web","private":true,"dependencies":{"is-number":"7.0.0"},"devDependencies":{"test-runner":"1.0.0"}}\n' > "$dir/web/package.json"
      printf '{"lockfileVersion":3}\n' > "$dir/web/package-lock.json"
      ;;
  esac
  case "$shape" in
    none)
      mkdir -p "$dir/docs" "$dir/src"
      printf '# docs\n' > "$dir/docs/README.md"
      printf 'int main(void) { return 0; }\n' > "$dir/src/main.c"
      ;;
  esac
}

# Run one library entry point in a subshell with the stub installers on PATH,
# printing "<rc> <summary>" plus whatever the library wrote to stderr.
run_provision() {
  local case_dir=$1 worktree=$2 fakebin=$3
  shift 3
  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  env "$@" \
    FM_TEST_INSTALL_LOG="$case_dir/install.log" \
    PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c '
      set -u
      . "$1"
      if fm_provision_worktree "$2" "$3" "$4"; then
        printf "rc=0 summary=%s\n" "$FM_PROVISION_SUMMARY"
      else
        printf "rc=%s summary=%s\n" "$?" "$FM_PROVISION_SUMMARY"
      fi
    ' _ "$LIB" "$worktree" "$case_dir/cache" "$case_dir/provision.log" 2>&1
}

new_case() {
  local name=$1 shape=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  make_worktree "$case_dir/wt" "$shape"
  make_installer_fakebin "$case_dir/fake" > "$case_dir/fakebin.path"
  : > "$case_dir/install.log"
  printf '%s\n' "$case_dir"
}

case_fakebin() { cat "$1/fakebin.path"; }

# --- library: no-op ---------------------------------------------------------

test_worktree_declaring_nothing_is_a_clean_noop() {
  local case_dir out
  case_dir=$(new_case noop none)
  out=$(run_provision "$case_dir" "$case_dir/wt" "$(case_fakebin "$case_dir")")
  assert_contains "$out" 'rc=0 summary=none' "a worktree with no recognized manifest should be a clean no-op: $out"
  [ ! -s "$case_dir/install.log" ] || fail "no-op provisioning still invoked an installer: $(cat "$case_dir/install.log")"
  [ ! -d "$case_dir/cache" ] || [ -z "$(ls -A "$case_dir/cache")" ] \
    || fail "no-op provisioning wrote a cache record"
  pass "a worktree declaring no recognized manifest provisions nothing and succeeds"
}

# --- library: install, then cache hit ---------------------------------------

test_first_spawn_installs_and_second_reuses_the_cache() {
  local case_dir out fakebin
  case_dir=$(new_case cache both)
  fakebin=$(case_fakebin "$case_dir")

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" NODE_ENV=production NPM_CONFIG_OMIT=dev)
  assert_contains "$out" 'rc=0' "cold provisioning failed: $out"
  assert_contains "$out" 'pip:svc=installed' "cold provisioning did not install the python component: $out"
  assert_contains "$out" 'npm:web=installed' "cold provisioning did not install the js component: $out"
  assert_grep 'uv venv --clear .venv' "$case_dir/install.log" "python provisioning did not create a uv virtualenv"
  assert_grep 'uv pip install' "$case_dir/install.log" "python provisioning did not install requirements"
  assert_grep 'npm ci' "$case_dir/install.log" "js provisioning did not run npm ci"
  assert_grep 'npm ci --include=dev' "$case_dir/install.log" "npm provisioning inherited an ambient development-dependency omission"
  [ -f "$case_dir/wt/web/node_modules/test-runner/package.json" ] \
    || fail "npm provisioning omitted a declared validation dependency"
  assert_grep 'requirements-test.txt' "$case_dir/install.log" \
    "python provisioning ignored the companion test requirements"

  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=0' "cache-hit provisioning failed: $out"
  assert_contains "$out" 'pip:svc=cached' "an unchanged python component was reinstalled: $out"
  assert_contains "$out" 'npm:web=cached' "an unchanged js component was reinstalled: $out"
  assert_no_grep 'npm ci' "$case_dir/install.log" "a cache hit still paid npm install cost"
  assert_no_grep 'uv pip install' "$case_dir/install.log" "a cache hit still paid uv install cost"
  pass "provisioning installs once and reuses an unchanged worktree without install cost"
}

test_a_changed_manifest_invalidates_the_cache() {
  local case_dir out fakebin
  case_dir=$(new_case manifest-change python)
  fakebin=$(case_fakebin "$case_dir")
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  printf 'six==1.16.0\nattrs==24.2.0\n' > "$case_dir/wt/svc/requirements.txt"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' "a changed requirements file did not invalidate the cache: $out"
  assert_grep 'uv pip install' "$case_dir/install.log" "a changed manifest did not trigger a reinstall"
  pass "a changed dependency manifest invalidates the cache"
}

test_a_removed_environment_invalidates_a_matching_fingerprint() {
  local case_dir out fakebin
  case_dir=$(new_case env-removed both)
  fakebin=$(case_fakebin "$case_dir")
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  rm -rf "$case_dir/wt/web/node_modules/is-number"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'npm:web=installed' "a deleted declared Node package was reported as cached: $out"
  assert_contains "$out" 'pip:svc=cached' "an untouched python component was needlessly reinstalled: $out"

  rm -f "$case_dir/wt/svc/.venv/lib/python3.11/site-packages/six.py"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' "a deleted declared Python package was reported as cached: $out"
  assert_contains "$out" 'npm:web=cached' "an untouched Node component was needlessly reinstalled: $out"

  rm -f "$case_dir/wt/svc/.venv/bin/pytest" "$case_dir/wt/web/node_modules/is-number/index.js"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'pip:svc=installed' "a deleted Python validation executable was reported as cached: $out"
  assert_contains "$out" 'npm:web=installed' "a changed declared Node package was reported as cached: $out"
  pass "a fingerprint match with a broken environment is a miss, not a hit"
}

test_node_installs_include_validation_dependencies() {
  local case_dir out fakebin
  case_dir=$(new_case node-validation-deps none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/tools"
  printf 'lockfileVersion: 9\n' > "$case_dir/wt/tools/pnpm-lock.yaml"
  printf '{"name":"tools","dependencies":{"is-number":"7.0.0"},"devDependencies":{"test-runner":"1.0.0"}}\n' \
    > "$case_dir/wt/tools/package.json"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" NODE_ENV=production)
  assert_contains "$out" 'pnpm:tools=installed' "pnpm provisioning failed under a production environment: $out"
  assert_grep 'pnpm install --frozen-lockfile --prod=false' "$case_dir/install.log" \
    "pnpm provisioning inherited an ambient development-dependency omission"
  [ -f "$case_dir/wt/tools/node_modules/test-runner/package.json" ] \
    || fail "pnpm provisioning omitted a declared validation dependency"
  pass "Node installs include declared validation dependencies deterministically"
}

test_a_replaced_interpreter_invalidates_the_cache() {
  local case_dir out fakebin
  case_dir=$(new_case interpreter-change python)
  fakebin=$(case_fakebin "$case_dir")
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  # Same manifests, but the virtualenv now reports a different interpreter than
  # the one recorded at install time.
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_TEST_PYTHON_VERSION=3.9.6)
  assert_contains "$out" 'pip:svc=installed' "a virtualenv whose interpreter changed was reported as cached: $out"
  pass "an environment whose recorded runtime no longer matches is reprovisioned"
}

# --- library: the failure contract ------------------------------------------

test_a_failing_install_refuses_the_spawn() {
  local case_dir out fakebin
  case_dir=$(new_case install-fail js)
  fakebin=$(case_fakebin "$case_dir")
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_TEST_NPM_FAIL=1)
  assert_contains "$out" 'rc=1' "a failing install did not refuse: $out"
  assert_contains "$out" 'the npm install in web exited 7' "the refusal did not name the component and exit code: $out"
  assert_contains "$out" 'could not run this project'"'"'s own checks' "the refusal did not state the consequence: $out"
  assert_contains "$out" '--no-provision' "the refusal did not name the opt-out: $out"
  [ ! -d "$case_dir/cache" ] || [ -z "$(ls -A "$case_dir/cache")" ] \
    || fail "a failed install still recorded a provisioning fingerprint"
  pass "a failing install refuses the spawn and records no fingerprint"
}

test_a_hung_install_is_bounded() {
  local case_dir out fakebin started elapsed
  case_dir=$(new_case install-hang js)
  fakebin=$(case_fakebin "$case_dir")
  started=$(date +%s)
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" \
    FM_TEST_NPM_SLEEP=60 FM_PROVISION_INSTALL_TIMEOUT=2)
  elapsed=$(( $(date +%s) - started ))
  assert_contains "$out" 'rc=1' "a hung install did not refuse: $out"
  assert_contains "$out" 'exceeded its 2s bound' "the refusal did not report the expired bound: $out"
  [ "$elapsed" -lt 30 ] || fail "a hung install was not bounded (took ${elapsed}s)"
  pass "an install that hangs is bounded and refuses instead of wedging the spawn"
}

test_a_missing_installer_refuses_the_spawn() {
  local case_dir out empty_bin
  case_dir=$(new_case installer-missing python)
  empty_bin="$case_dir/empty-bin"
  mkdir -p "$empty_bin"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$empty_bin")
  assert_contains "$out" 'rc=1' "a missing installer did not refuse: $out"
  assert_contains "$out" 'uv is not installed' "the refusal did not name the missing installer: $out"
  assert_contains "$out" 'never pip or venv' "the refusal did not restate the uv-only python convention: $out"
  pass "a python project with no uv refuses the spawn instead of launching unprovisioned"
}

test_an_unsupported_package_manager_refuses_the_spawn() {
  local case_dir out fakebin
  case_dir=$(new_case unsupported none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/app"
  printf '# yarn lockfile v1\n' > "$case_dir/wt/app/yarn.lock"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'rc=1' "an unsupported lockfile did not refuse: $out"
  assert_contains "$out" 'declares a yarn lockfile' "the refusal did not name the unsupported manager: $out"
  [ ! -s "$case_dir/install.log" ] \
    || fail "an unsupported component was detected only after other installs ran: $(cat "$case_dir/install.log")"
  pass "a recognized but unsupported package manager refuses before anything is installed"
}

test_too_many_components_refuse_the_spawn() {
  local case_dir out fakebin i
  case_dir=$(new_case too-many none)
  fakebin=$(case_fakebin "$case_dir")
  for i in 1 2 3; do
    mkdir -p "$case_dir/wt/pkg$i"
    printf 'six\n' > "$case_dir/wt/pkg$i/requirements.txt"
  done
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" FM_PROVISION_MAX_COMPONENTS=2)
  assert_contains "$out" 'rc=1' "an oversized component set did not refuse: $out"
  assert_contains "$out" 'above the FM_PROVISION_MAX_COMPONENTS limit' "the refusal did not name the limit: $out"
  pass "more components than the configured limit refuses rather than fanning out installs"
}

# --- library: detection is per-project, not hardcoded ------------------------

test_detection_is_declaration_driven_and_prunes_installed_trees() {
  local case_dir out
  case_dir=$(new_case detect both)
  # Nested already-installed trees must never be mistaken for components.
  mkdir -p "$case_dir/wt/web/node_modules/dep" "$case_dir/wt/svc/.venv/lib"
  printf '{"lockfileVersion":3}\n' > "$case_dir/wt/web/node_modules/dep/package-lock.json"
  printf 'six\n' > "$case_dir/wt/svc/.venv/lib/requirements.txt"
  # Two more declared stacks, one of them at the worktree root.
  mkdir -p "$case_dir/wt/tools"
  printf 'lockfileVersion: 9\n' > "$case_dir/wt/tools/pnpm-lock.yaml"
  printf '{"name":"tools"}\n' > "$case_dir/wt/tools/package.json"
  printf 'version = 1\n' > "$case_dir/wt/uv.lock"
  printf '[project]\nname = "root"\n' > "$case_dir/wt/pyproject.toml"

  out=$(PATH="/usr/bin:/bin" bash -c '
    set -u
    . "$1"
    fm_provision_detect "$2"
  ' _ "$LIB" "$case_dir/wt" | LC_ALL=C sort | tr '\n' '|')
  expect_code 0 $? "detection failed"
  assert_contains "$out" 'npm web|' "a package-lock.json component was not detected: $out"
  assert_contains "$out" 'pip svc|' "a requirements.txt component was not detected: $out"
  assert_contains "$out" 'pnpm tools|' "a pnpm-lock.yaml component was not detected: $out"
  assert_contains "$out" 'uv .|' "a uv.lock component at the worktree root was not detected: $out"
  assert_not_contains "$out" 'node_modules' "detection descended into an installed node_modules tree: $out"
  assert_not_contains "$out" '.venv' "detection descended into an installed virtualenv: $out"
  pass "detection is driven by what the worktree declares and skips installed trees"
}

test_a_uv_workspace_syncs_every_member() {
  local case_dir fakebin out
  case_dir=$(new_case uv-workspace none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/mono/packages/alpha" "$case_dir/wt/solo"
  printf 'version = 1\n' > "$case_dir/wt/mono/uv.lock"
  printf '[project]\nname = "mono"\n\n  [tool.uv.workspace]\nmembers = ["packages/*"]\n' \
    > "$case_dir/wt/mono/pyproject.toml"
  printf 'version = 1\n' > "$case_dir/wt/solo/uv.lock"
  printf '[project]\nname = "solo"\n' > "$case_dir/wt/solo/pyproject.toml"

  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" \
    FM_TEST_REQUIRE_UV_DEFAULT_GROUPS=1 UV_NO_DEV=1 UV_ONLY_DEV=1 \
    UV_NO_DEFAULT_GROUPS=1 UV_NO_GROUP=dev UV_ONLY_GROUP=runtime)
  assert_contains "$out" 'rc=0' "uv provisioning failed: $out"
  # A workspace has one uv.lock and one .venv at its root, so a plain sync
  # would install only the root package and leave a member's checks unrunnable.
  assert_grep 'uv sync --frozen --all-packages' "$case_dir/install.log" \
    "a declared uv workspace was synced without its members"
  grep -qxF 'uv sync --frozen' "$case_dir/install.log" \
    || fail "a non-workspace uv project did not use the plain sync form"
  assert_no_grep ' --dev' "$case_dir/install.log" \
    "uv provisioning depended on the undocumented --dev alias"
  pass "a uv workspace syncs every member while a single project keeps the plain sync"
}

test_a_uv_workspace_member_manifest_invalidates_the_cache() {
  local case_dir fakebin out
  case_dir=$(new_case uv-workspace-manifest none)
  fakebin=$(case_fakebin "$case_dir")
  mkdir -p "$case_dir/wt/mono/packages/alpha"
  printf 'version = 1\n' > "$case_dir/wt/mono/uv.lock"
  printf '[project]\nname = "mono"\n\n  [tool.uv.workspace]\nmembers = ["packages/*"]\n' \
    > "$case_dir/wt/mono/pyproject.toml"
  printf '[project]\nname = "alpha"\nversion = "1.0.0"\n' \
    > "$case_dir/wt/mono/packages/alpha/pyproject.toml"
  printf '3.11\n' > "$case_dir/wt/mono/packages/alpha/.python-version"
  run_provision "$case_dir" "$case_dir/wt" "$fakebin" >/dev/null

  printf '[project]\nname = "alpha"\nversion = "1.0.1"\n' \
    > "$case_dir/wt/mono/packages/alpha/pyproject.toml"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'uv:mono=installed' "a changed uv member manifest did not invalidate the cache: $out"
  assert_grep 'uv sync --frozen --all-packages' "$case_dir/install.log" \
    "a changed uv member manifest did not trigger a workspace reinstall"

  printf '3.12\n' > "$case_dir/wt/mono/packages/alpha/.python-version"
  : > "$case_dir/install.log"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin")
  assert_contains "$out" 'uv:mono=installed' "a changed uv member Python declaration did not invalidate the cache: $out"
  assert_grep 'uv sync --frozen --all-packages' "$case_dir/install.log" \
    "a changed uv member Python declaration did not trigger a workspace reinstall"
  pass "uv workspace member manifests participate in the cache fingerprint"
}

test_declared_node_version_is_read_only_when_unambiguous() {
  local case_dir probe
  case_dir=$(new_case node-declaration none)
  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  probe='
    set -u
    . "$1"
    printf "%s\n" "$(fm_provision_declared_node_major "$2")"
  '
  mkdir -p "$case_dir/nvmrc" "$case_dir/engines" "$case_dir/range" "$case_dir/silent"
  printf '20\n' > "$case_dir/nvmrc/.nvmrc"
  printf '{"engines":{"node":"^18.17.0"}}\n' > "$case_dir/engines/package.json"
  printf '{"engines":{"node":">=18 <21"}}\n' > "$case_dir/range/package.json"
  printf '{"name":"silent"}\n' > "$case_dir/silent/package.json"

  expect_equal() {
    local got want label
    got=$(PATH="/usr/bin:/bin" bash -c "$probe" _ "$LIB" "$1")
    want=$2
    label=$3
    [ "$got" = "$want" ] || fail "$label (got '$got', want '$want')"
  }
  expect_equal "$case_dir/nvmrc" 20 ".nvmrc was not read as an exact pin"
  expect_equal "$case_dir/engines" 18 "a caret engines pin was not reduced to its major"
  expect_equal "$case_dir/range" '' "a real engines range was treated as a pin"
  expect_equal "$case_dir/silent" '' "a package.json declaring no engine produced a pin"
  pass "a Node pin is read from what the project declares, and only when unambiguous"
}

test_a_declared_but_absent_node_runtime_refuses_the_spawn() {
  local case_dir out fakebin
  case_dir=$(new_case node-absent js)
  fakebin=$(case_fakebin "$case_dir")
  printf '99\n' > "$case_dir/wt/web/.nvmrc"
  out=$(run_provision "$case_dir" "$case_dir/wt" "$fakebin" NVM_DIR="$case_dir/no-nvm" \
    FNM_DIR="$case_dir/no-fnm" VOLTA_HOME="$case_dir/no-volta" HOME="$case_dir/no-home")
  assert_contains "$out" 'rc=1' "an unsatisfiable Node pin did not refuse: $out"
  assert_contains "$out" 'declares Node 99' "the refusal did not name the declared runtime: $out"
  [ ! -s "$case_dir/install.log" ] || fail "an unsatisfiable Node pin still ran an install"
  pass "a declared Node runtime that cannot be found refuses before installing"
}

test_a_declared_node_runtime_is_resolved_and_exported() {
  local case_dir out fakebin nvm_bin
  case_dir=$(new_case node-pinned js)
  fakebin=$(case_fakebin "$case_dir")
  printf '20\n' > "$case_dir/wt/web/.nvmrc"
  # Two installed majors; the highest matching one must win, and the ambient
  # node (which reports 23) must lose to the declared pin.
  nvm_bin="$case_dir/nvm/versions/node/v20.20.2/bin"
  mkdir -p "$nvm_bin" "$case_dir/nvm/versions/node/v20.19.0/bin" "$case_dir/nvm/versions/node/v18.20.6/bin"
  cat > "$nvm_bin/node" <<'SH'
#!/usr/bin/env bash
printf '20.20.2'
SH
  chmod +x "$nvm_bin/node"
  cp "$nvm_bin/node" "$case_dir/nvm/versions/node/v20.19.0/bin/node"
  cp "$nvm_bin/node" "$case_dir/nvm/versions/node/v18.20.6/bin/node"

  # shellcheck disable=SC2016  # the bash -c body expands its own positionals
  out=$(env FM_TEST_INSTALL_LOG="$case_dir/install.log" FM_TEST_NODE_VERSION=23.8.0 \
    NVM_DIR="$case_dir/nvm" FNM_DIR="$case_dir/no-fnm" VOLTA_HOME="$case_dir/no-volta" \
    PATH="$fakebin:/usr/bin:/bin" \
    bash -c '
      set -u
      . "$1"
      fm_provision_worktree "$2" "$3" "$4" || exit 1
      printf "prefix=%s\n" "$FM_PROVISION_PATH_PREFIX"
    ' _ "$LIB" "$case_dir/wt" "$case_dir/cache" "$case_dir/provision.log" 2>&1)
  assert_contains "$out" "prefix=$nvm_bin" "the declared Node runtime was not resolved and exported: $out"
  assert_contains "$out" 'pinning Node 20' "the pinned runtime was not surfaced: $out"
  pass "a declared Node runtime is resolved to its highest installed match and exported for the lane"
}

# --- fm-spawn.sh integration ------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(make_installer_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_TEST_INSTALL_LOG:-}" ]; then
      printf 'LAUNCH %s\n' "$*" >> "$FM_TEST_INSTALL_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_WORKTREE:?}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 shape=$2 id=$3 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/treehouse-pools"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  # Dependency manifests are TRACKED project files, so they must be committed
  # before the worktree is cut: an acquired worktree carrying uncommitted files
  # fails the cleanliness proof long before provisioning is reached.
  fm_git_init_commit "$project"
  make_worktree "$project" "$shape"
  git -C "$project" add -A
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'project manifests'
  git -C "$project" worktree add --quiet --detach "$worktree"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '# Backlog\n\n## In flight\n- [ ] %s - provisioning test (repo: project)\n\n## Queued\n\n## Done\n' \
    "$id" > "$home/data/backlog.md"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  : > "$case_dir/install.log"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 worktree=$3 fakebin=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TREEHOUSE_ROOT="$home/treehouse-pools" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$home/checkout-refresh-state" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_WORKTREE="$worktree" \
    FM_TEST_INSTALL_LOG="$case_dir/install.log" \
    PATH="$fakebin:$PATH" "$SPAWN" "$@" 2>&1
}

test_spawn_provisions_the_worktree_before_creating_the_endpoint() {
  local record id out status order
  id=provision-spawn-p1
  record=$(make_spawn_case spawn-ok both "$id")
  read_spawn_case "$record"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a spawn into a provisionable worktree should succeed: $out"
  assert_contains "$out" "spawned $id" "the spawn did not reach endpoint creation: $out"
  assert_grep 'npm ci' "$CASE_DIR/install.log" "the spawn did not provision the js component"
  assert_grep 'uv pip install' "$CASE_DIR/install.log" "the spawn did not provision the python component"
  assert_grep 'provision=pip:svc=installed,npm:web=installed' "$HOME_DIR/state/$id.meta" \
    "the spawn did not record its provisioning outcome in task metadata"
  # Ordering is the contract: a lane must never be launched into a worktree
  # whose dependencies are still installing.
  order=$(grep -n -m1 -e 'npm ci' -e 'LAUNCH' "$CASE_DIR/install.log" | cut -d: -f2-)
  case "$order" in
    LAUNCH*) fail "the endpoint was launched before provisioning ran" ;;
  esac
  [ -f "$HOME_DIR/state/$id.provision.log" ] || fail "the spawn wrote no provisioning log"
  pass "a spawn provisions its worktree after verification and before endpoint creation"
}

test_spawn_refuses_when_provisioning_fails() {
  local record id out status
  id=provision-spawn-p2
  record=$(make_spawn_case spawn-fail js "$id")
  read_spawn_case "$record"
  out=$(FM_TEST_NPM_FAIL=1 run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a spawn whose provisioning failed should be refused: $out"
  assert_contains "$out" 'worktree provisioning failed' "the spawn did not report the provisioning failure: $out"
  assert_not_contains "$out" "spawned $id" "a spawn with failed provisioning still reported success: $out"
  assert_no_grep 'LAUNCH' "$CASE_DIR/install.log" "a lane was launched into an unprovisioned worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn wrote task metadata"
  pass "provisioning failure refuses the spawn instead of launching a lane that cannot validate"
}

test_spawn_failure_excludes_every_mutated_component() {
  local record id out status exclude_file dirty
  id=provision-spawn-p7
  record=$(make_spawn_case spawn-multi-fail both "$id")
  read_spawn_case "$record"
  out=$(FM_TEST_NPM_FAIL=1 run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a later component failure should refuse the spawn: $out"
  assert_grep 'uv pip install' "$CASE_DIR/install.log" "the earlier Python component did not install before the Node failure"
  assert_grep 'npm ci' "$CASE_DIR/install.log" "the later Node component did not reach its failing installer"
  exclude_file=$(git -C "$WORKTREE_DIR" rev-parse --git-path info/exclude)
  assert_grep '/svc/.venv/' "$exclude_file" "the successful earlier component was not excluded after a later failure"
  assert_grep '/web/node_modules/' "$exclude_file" "the partially created failing component was not excluded"
  dirty=$(git -C "$WORKTREE_DIR" status --porcelain --untracked-files=all)
  [ -z "$dirty" ] || fail "a multi-component provisioning failure left the leased worktree dirty: $dirty"
  pass "a later provisioning failure leaves every mutated component excluded"
}

test_spawn_refuses_before_install_when_exclusion_cannot_be_registered() {
  local record id out status exclude_file
  id=provision-spawn-p8
  record=$(make_spawn_case spawn-exclude-fail both "$id")
  read_spawn_case "$record"
  exclude_file=$(git -C "$WORKTREE_DIR" rev-parse --git-path info/exclude)
  chmod 400 "$exclude_file"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  chmod 600 "$exclude_file"
  expect_code 1 "$status" "an unwritable exclusion target should refuse the spawn: $out"
  assert_contains "$out" 'cannot register the git exclusion' \
    "the refusal did not identify exclusion registration: $out"
  [ ! -s "$CASE_DIR/install.log" ] \
    || fail "an installer ran before exclusion registration succeeded: $(cat "$CASE_DIR/install.log")"
  assert_not_contains "$out" "spawned $id" "a spawn with an unprotected dependency directory still succeeded: $out"
  pass "an exclusion failure refuses before any installer mutates the worktree"
}

test_provisioning_can_be_opted_out_per_spawn_and_per_home() {
  local record id out status
  id=provision-spawn-p3
  record=$(make_spawn_case spawn-flag-off both "$id")
  read_spawn_case "$record"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --no-provision)
  status=$?
  expect_code 0 "$status" "--no-provision should still spawn: $out"
  assert_no_grep 'npm ci' "$CASE_DIR/install.log" "--no-provision still installed dependencies"
  assert_grep 'provision=off' "$HOME_DIR/state/$id.meta" "--no-provision was not recorded in task metadata"

  id=provision-spawn-p4
  record=$(make_spawn_case spawn-config-off both "$id")
  read_spawn_case "$record"
  printf 'off\n' > "$HOME_DIR/config/worktree-provision"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "config/worktree-provision=off should still spawn: $out"
  assert_no_grep 'npm ci' "$CASE_DIR/install.log" "config/worktree-provision=off still installed dependencies"
  assert_grep 'provision=off' "$HOME_DIR/state/$id.meta" "the home opt-out was not recorded in task metadata"
  pass "provisioning is opt-out per spawn and per home, and the choice is recorded"
}

test_an_unreadable_provisioning_setting_refuses_the_spawn() {
  local record id out status
  id=provision-spawn-p5
  record=$(make_spawn_case spawn-config-bad js "$id")
  read_spawn_case "$record"
  printf 'maybe\n' > "$HOME_DIR/config/worktree-provision"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "an invalid provisioning setting should refuse: $out"
  assert_contains "$out" "config/worktree-provision must contain exactly 'on' or 'off'" \
    "the refusal did not name the invalid setting: $out"
  pass "an unparseable provisioning setting refuses rather than silently disabling the gate"
}

test_spawn_into_an_undeclared_project_is_unchanged() {
  local record id out status
  id=provision-spawn-p6
  record=$(make_spawn_case spawn-noop none "$id")
  read_spawn_case "$record"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a spawn into a project declaring no dependencies should succeed: $out"
  assert_contains "$out" "spawned $id" "the spawn did not reach endpoint creation: $out"
  assert_grep 'provision=none' "$HOME_DIR/state/$id.meta" "a no-op provisioning was not recorded"
  pass "a project declaring no recognized manifest spawns exactly as before"
}

test_worktree_declaring_nothing_is_a_clean_noop
test_first_spawn_installs_and_second_reuses_the_cache
test_a_changed_manifest_invalidates_the_cache
test_a_removed_environment_invalidates_a_matching_fingerprint
test_node_installs_include_validation_dependencies
test_a_replaced_interpreter_invalidates_the_cache
test_a_failing_install_refuses_the_spawn
test_a_hung_install_is_bounded
test_a_missing_installer_refuses_the_spawn
test_an_unsupported_package_manager_refuses_the_spawn
test_too_many_components_refuse_the_spawn
test_detection_is_declaration_driven_and_prunes_installed_trees
test_a_uv_workspace_syncs_every_member
test_a_uv_workspace_member_manifest_invalidates_the_cache
test_declared_node_version_is_read_only_when_unambiguous
test_a_declared_but_absent_node_runtime_refuses_the_spawn
test_a_declared_node_runtime_is_resolved_and_exported
test_spawn_provisions_the_worktree_before_creating_the_endpoint
test_spawn_refuses_when_provisioning_fails
test_spawn_failure_excludes_every_mutated_component
test_spawn_refuses_before_install_when_exclusion_cannot_be_registered
test_provisioning_can_be_opted_out_per_spawn_and_per_home
test_an_unreadable_provisioning_setting_refuses_the_spawn
test_spawn_into_an_undeclared_project_is_unchanged

echo "# all fm-spawn-provision tests passed"
