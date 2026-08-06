#!/usr/bin/env bash
# fm-provision-lib.sh - provision a task worktree's project dependencies.
#
# Sourced by bin/fm-spawn.sh. A git worktree carries only tracked files, so the
# gitignored machinery a project needs to RUN its own checks - a Python virtual
# environment, an installed node_modules - never arrives with it. Treehouse
# v2.0.0 exposes no setup hook, so a freshly leased worktree has the source and
# none of the tooling. A lane in that state cannot run the project's tests,
# formatters, or browser checks, so it ships on another agent's evidence or on
# none. This library closes that gap between worktree verification and endpoint
# launch.
#
# CONTRACT (one mode, no silent degradation)
#   Provisioning either succeeds or the spawn fails. There is no "launched but
#   degraded" state, because a lane that cannot validate its own work is the
#   exact defect this exists to remove, and a recorded-degradation mode would
#   reintroduce it one indirection away. A worktree that declares no recognized
#   dependency manifest is a clean no-op, not a failure. Every other outcome -
#   a recognized manifest whose installer is missing, an install that fails, an
#   install that exceeds its bound, a declared runtime that cannot be found, a
#   recognized-but-unsupported package manager - refuses the spawn and names
#   both the cause and the opt-out. fm-spawn.sh's --no-provision flag and the
#   home-local config/worktree-provision file are the opt-out; the caller owns
#   reading them.
#
# DETECTION is per-project and declaration-driven. Nothing here knows the name
# of any project, and no interpreter or runtime version is hardcoded: uv reads
# the project's own .python-version / requires-python, and a Node pin is read
# from the project's .nvmrc or package.json engines.node. A stack this library
# does not recognize provisions nothing.
#
# SUPPORTED ECOSYSTEMS (one component per directory per language)
#   uv      uv.lock            -> uv sync --frozen
#   pip     requirements.txt   -> uv venv --clear .venv + uv pip install -r ...
#   npm     package-lock.json  -> npm ci
#   pnpm    pnpm-lock.yaml     -> pnpm install --frozen-lockfile
# Python always goes through uv, never pip/venv directly (AGENTS.md toolchain
# convention). yarn and bun lockfiles are recognized but unsupported: they
# refuse the spawn rather than silently leaving a lane unprovisioned, because
# no verified install invocation for them exists in this repo yet.
#
# CACHING. Every component carries a fingerprint over its own manifests plus
# the resolved installer and runtime identity. A cache hit needs BOTH a
# matching fingerprint AND a live readiness probe of the installed environment,
# because a pool slot's ignored directories survive leases but a previous agent
# may have deleted or broken them - directory existence alone is not readiness
# (data/v3-env-repair-e3/report.md, 2026-08-05). Records live in firstmate's
# state dir, never in the worktree, so provisioning cannot dirty a checkout that
# teardown and the freshness proof both require to be clean.
#
# BOUNDS. Every install and probe runs through fm_provision_run_bounded, which
# reuses bin/fm-crew-state.sh's timeout/gtimeout/perl-alarm pattern verbatim
# (this machine has neither timeout nor gtimeout). With no bounding mechanism
# available, provisioning refuses rather than risking an unbounded install
# wedging a spawn.
#
# Tunables (seconds unless noted):
#   FM_PROVISION_SCAN_DEPTH=4        manifest search depth below the worktree
#   FM_PROVISION_MAX_COMPONENTS=8    refuse above this many detected components
#   FM_PROVISION_INSTALL_TIMEOUT=600 per-component install bound
#   FM_PROVISION_PROBE_TIMEOUT=60    per-readiness-probe bound

FM_PROVISION_SCAN_DEPTH=${FM_PROVISION_SCAN_DEPTH:-4}
FM_PROVISION_MAX_COMPONENTS=${FM_PROVISION_MAX_COMPONENTS:-8}
FM_PROVISION_INSTALL_TIMEOUT=${FM_PROVISION_INSTALL_TIMEOUT:-600}
FM_PROVISION_PROBE_TIMEOUT=${FM_PROVISION_PROBE_TIMEOUT:-60}

# Bumped whenever a recorded field's meaning changes; a record from another
# schema is treated as a miss rather than misread.
FM_PROVISION_CACHE_SCHEMA=4

# Outputs of fm_provision_worktree, read by the sourcing caller (fm-spawn.sh),
# so shellcheck cannot see their consumers from this file alone.
# shellcheck disable=SC2034
FM_PROVISION_SUMMARY=
# shellcheck disable=SC2034
FM_PROVISION_PATH_PREFIX=
# shellcheck disable=SC2034
FM_PROVISION_EXCLUDES=

# --- primitives -------------------------------------------------------------

fm_provision_sha256() {  # reads stdin, prints the hex digest
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  else
    python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  fi
}

# Which bounding mechanism this host has. Resolved once; "none" refuses.
FM_PROVISION_BOUND_KIND=
fm_provision_bound_kind() {
  if [ -z "$FM_PROVISION_BOUND_KIND" ]; then
    if command -v timeout >/dev/null 2>&1; then FM_PROVISION_BOUND_KIND=timeout
    elif command -v gtimeout >/dev/null 2>&1; then FM_PROVISION_BOUND_KIND=gtimeout
    elif command -v perl >/dev/null 2>&1; then FM_PROVISION_BOUND_KIND=perl
    else FM_PROVISION_BOUND_KIND=none
    fi
  fi
  printf '%s' "$FM_PROVISION_BOUND_KIND"
}

# Run a command with cwd and a hard wall-clock bound, preserving its exit code.
# Exit 124 means the bound expired; exit 125 means this host cannot bound at all.
# The perl branch is bin/fm-crew-state.sh's established alarm wrapper, unchanged.
fm_provision_run_bounded() {  # <seconds> <cwd> <cmd> [args...]
  local secs=$1 cwd=$2
  shift 2
  case "$(fm_provision_bound_kind)" in
    timeout)  ( cd "$cwd" && timeout "$secs" "$@" ) ;;
    gtimeout) ( cd "$cwd" && gtimeout "$secs" "$@" ) ;;
    perl)     ( cd "$cwd" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$@" ) ;;
    *)        return 125 ;;
  esac
}

# Same bound, with all output appended to the provisioning log.
fm_provision_run_logged() {  # <seconds> <cwd> <log> <cmd> [args...]
  local secs=$1 cwd=$2 log=$3 rc=0
  shift 3
  printf '\n$ (cd %s) %s\n' "$cwd" "$*" >> "$log"
  fm_provision_run_bounded "$secs" "$cwd" "$@" >> "$log" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc" >> "$log"
  return "$rc"
}

# First line of a tool's own version output; empty when the tool is absent.
fm_provision_tool_version() {  # <tool> [args...]
  local tool=$1 out=
  shift
  command -v "$tool" >/dev/null 2>&1 || return 1
  out=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$PWD" "$tool" "$@" 2>/dev/null | head -1) || return 1
  printf '%s' "$out"
}

# --- home configuration -----------------------------------------------------

# Resolve the home's provisioning posture from config/worktree-provision.
# Absent or "on" enables it; "off" disables it. Anything else is a refusal,
# because a typo must not silently disable the gate this exists to hold.
fm_provision_mode() {  # <config-dir>
  local config_dir=${1:-} file value
  file="$config_dir/worktree-provision"
  [ -n "$config_dir" ] && [ -e "$file" ] || { printf 'on'; return 0; }
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'invalid'
    return 1
  fi
  value=$(tr -d '[:space:]' < "$file")
  case "$value" in
    ''|on) printf 'on' ;;
    off) printf 'off' ;;
    *) printf 'invalid'; return 1 ;;
  esac
}

# --- detection --------------------------------------------------------------

# Emit "<ecosystem> <relative-dir>" per detected component, deterministically
# ordered. A directory can yield at most one Python and one JS component.
fm_provision_detect() {  # <worktree>
  local wt=$1 file dir rel
  local -a manifests=()
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    manifests+=("$file")
  done < <(
    find "$wt" -maxdepth "$FM_PROVISION_SCAN_DEPTH" \
      \( -name .git -o -name node_modules -o -name .venv -o -name venv \
         -o -name .tox -o -name .nox -o -name .mypy_cache -o -name __pycache__ \
         -o -name site-packages -o -name vendor -o -name target -o -name dist \
         -o -name build -o -name .next -o -name .treehouse \) -prune -o \
      -type f \( -name uv.lock -o -name requirements.txt \
                 -o -name package-lock.json -o -name pnpm-lock.yaml \
                 -o -name yarn.lock -o -name bun.lockb -o -name bun.lock \) \
      -print 2>/dev/null | LC_ALL=C sort
  )
  [ "${#manifests[@]}" -gt 0 ] || return 0

  local -a dirs=()
  for file in "${manifests[@]}"; do
    dir=$(dirname "$file")
    rel=${dir#"$wt"}
    rel=${rel#/}
    [ -n "$rel" ] || rel=.
    case " ${dirs[*]-} " in *" $rel "*) continue ;; esac
    dirs+=("$rel")
  done

  for rel in "${dirs[@]}"; do
    dir=$wt/$rel
    [ "$rel" != . ] || dir=$wt
    # Python: uv-managed project wins over a bare requirements install.
    if [ -f "$dir/uv.lock" ]; then
      printf '%s %s\n' uv "$rel"
    elif [ -f "$dir/requirements.txt" ]; then
      printf '%s %s\n' pip "$rel"
    fi
    # JS: the lockfile names the package manager. Precedence is fixed so a
    # directory carrying two lockfiles still resolves deterministically.
    if [ -f "$dir/pnpm-lock.yaml" ]; then
      printf '%s %s\n' pnpm "$rel"
    elif [ -f "$dir/yarn.lock" ]; then
      printf '%s %s\n' yarn "$rel"
    elif [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then
      printf '%s %s\n' bun "$rel"
    elif [ -f "$dir/package-lock.json" ]; then
      printf '%s %s\n' npm "$rel"
    fi
  done
}

fm_provision_uv_workspace_info() {  # <component-dir>
  local dir=$1
  [ -f "$dir/pyproject.toml" ] || return 0
  fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
    python3 - "$dir" <<'PY'
import ast
import os
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
lines = (root / "pyproject.toml").read_text(encoding="utf-8").splitlines()
start = next((index for index, line in enumerate(lines) if re.fullmatch(r"\s*\[tool\.uv\.workspace\]\s*(?:#.*)?", line)), None)
if start is None:
    raise SystemExit(0)
print("workspace")

def without_comment(line):
    quote = None
    escaped = False
    out = []
    for char in line:
        if escaped:
            out.append(char)
            escaped = False
            continue
        if quote == '"' and char == "\\":
            out.append(char)
            escaped = True
            continue
        if char in ("'", '"'):
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
            out.append(char)
            continue
        if char == "#" and quote is None:
            break
        out.append(char)
    return "".join(out)

def bracket_depth(value):
    quote = None
    escaped = False
    depth = 0
    for char in value:
        if escaped:
            escaped = False
            continue
        if quote == '"' and char == "\\":
            escaped = True
            continue
        if char in ("'", '"'):
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
            continue
        if quote is None:
            depth += (char == "[") - (char == "]")
    return depth

values = {}
index = start + 1
while index < len(lines):
    line = without_comment(lines[index]).strip()
    if line.startswith("["):
        break
    match = re.match(r"^(members|exclude)\s*=\s*(.*)$", line)
    if not match:
        index += 1
        continue
    key, value = match.groups()
    if key in values:
        raise SystemExit(1)
    while bracket_depth(value) > 0:
        index += 1
        if index >= len(lines):
            raise SystemExit(1)
        value += "\n" + without_comment(lines[index])
    try:
        parsed = ast.literal_eval(value)
    except (SyntaxError, ValueError):
        raise SystemExit(1)
    if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
        raise SystemExit(1)
    values[key] = parsed
    index += 1

members = values.get("members", [])
excludes = values.get("exclude", [])

def matches(patterns):
    found = set()
    for pattern in patterns:
        if os.path.isabs(pattern):
            raise SystemExit(1)
        for candidate in root.glob(pattern):
            resolved = candidate.resolve()
            try:
                resolved.relative_to(root)
            except ValueError:
                raise SystemExit(1)
            if resolved.is_dir():
                found.add(resolved)
    return found

member_dirs = matches(members) - matches(excludes)
paths = []
for member in member_dirs:
    manifest = member / "pyproject.toml"
    if not manifest.is_file():
        continue
    paths.append(manifest.relative_to(root).as_posix())
    python_version = member / ".python-version"
    if python_version.is_file():
        paths.append(python_version.relative_to(root).as_posix())
for path in sorted(paths):
    print(path)
PY
}

# The files whose content defines a component's fingerprint. Only files that
# exist are listed, so an added or removed optional manifest is itself a change.
fm_provision_manifests() {  # <worktree> <ecosystem> <relative-dir>
  local wt=$1 eco=$2 rel=$3 dir name workspace_info
  dir=$wt/$rel
  [ "$rel" != . ] || dir=$wt
  local -a names=()
  case "$eco" in
    uv) names=(uv.lock pyproject.toml .python-version) ;;
    pip)
      names=(requirements.txt requirements-dev.txt requirements-test.txt
             requirements_dev.txt requirements_test.txt
             constraints.txt pyproject.toml .python-version)
      ;;
    npm) names=(package-lock.json package.json .nvmrc) ;;
    pnpm) names=(pnpm-lock.yaml package.json pnpm-workspace.yaml .nvmrc) ;;
    *) return 0 ;;
  esac
  for name in "${names[@]}"; do
    [ -f "$dir/$name" ] || continue
    printf '%s\n' "$name"
  done
  if [ "$eco" = uv ]; then
    workspace_info=$(fm_provision_uv_workspace_info "$dir") || return 1
    while IFS= read -r name; do
      [ -n "$name" ] && [ "$name" != workspace ] || continue
      printf '%s\n' "$name"
    done <<< "$workspace_info"
  fi
}

# The requirements files a pip component installs: requirements.txt plus the
# conventional dev/test companions. Deliberately not a requirements*.txt glob,
# which would sweep in mutually exclusive variants.
fm_provision_pip_requirements() {  # <component-dir>
  local dir=$1 name
  for name in requirements.txt requirements-dev.txt requirements-test.txt \
    requirements_dev.txt requirements_test.txt; do
    [ -f "$dir/$name" ] || continue
    printf '%s\n' "$name"
  done
}

# --- node runtime resolution ------------------------------------------------

# The Node major version a component pins, or empty when it declares none.
# .nvmrc is an exact pin by definition. engines.node is accepted only in
# unambiguous single-major forms; a real range ('>=18 <21', '18 || 20') leaves
# the runtime unpinned rather than guessing which end the project meant.
fm_provision_declared_node_major() {  # <component-dir>
  local dir=$1 raw='' major=''
  if [ -f "$dir/.nvmrc" ]; then
    raw=$(tr -d '[:space:]' < "$dir/.nvmrc")
  elif [ -f "$dir/package.json" ]; then
    raw=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "rb") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
engines = data.get("engines")
if isinstance(engines, dict):
    node = engines.get("node")
    if isinstance(node, str):
        sys.stdout.write(node.strip())
' "$dir/package.json" 2>/dev/null) || raw=
  fi
  [ -n "$raw" ] || return 0
  case "$raw" in
    *' '*|*'||'*|*'>'*|*'<'*|*'-'*) return 0 ;;
  esac
  raw=${raw#v}
  raw=${raw#^}
  raw=${raw#\~}
  raw=${raw#=}
  major=${raw%%.*}
  case "$major" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s' "$major"
}

# Highest installed Node whose major matches, searched through the standard
# version-manager layouts only (env-var driven, no captain-specific path).
# Prints the bin directory; empty when nothing matches.
fm_provision_find_node_bin() {  # <major>
  local major=$1 candidate best=
  local -a roots=()
  roots+=("${NVM_DIR:-$HOME/.nvm}/versions/node")
  roots+=("${FNM_DIR:-$HOME/.local/share/fnm}/node-versions")
  roots+=("${VOLTA_HOME:-$HOME/.volta}/tools/image/node")
  roots+=("$HOME/.asdf/installs/nodejs")
  local root name
  local -a found=()
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    for candidate in "$root"/*; do
      [ -d "$candidate" ] || continue
      name=$(basename "$candidate")
      name=${name#v}
      case "$name" in "$major"|"$major".*) ;; *) continue ;; esac
      if [ -x "$candidate/bin/node" ]; then
        found+=("$name $candidate/bin")
      elif [ -x "$candidate/installation/bin/node" ]; then
        found+=("$name $candidate/installation/bin")
      fi
    done
  done
  if [ "${#found[@]}" -gt 0 ]; then
    best=$(printf '%s\n' "${found[@]}" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    printf '%s' "${best#* }"
    return 0
  fi
  return 0
}

# --- fingerprint and cache --------------------------------------------------

fm_provision_fingerprint() {  # <worktree> <eco> <rel> <installer-id> <runtime-id>
  local wt=$1 eco=$2 rel=$3 installer=$4 runtime=$5 dir name manifests
  dir=$wt/$rel
  [ "$rel" != . ] || dir=$wt
  manifests=$(fm_provision_manifests "$wt" "$eco" "$rel") || return 1
  {
    printf 'schema=%s\n' "$FM_PROVISION_CACHE_SCHEMA"
    printf 'ecosystem=%s\n' "$eco"
    printf 'component=%s\n' "$rel"
    printf 'installer=%s\n' "$installer"
    printf 'runtime=%s\n' "$runtime"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      printf 'manifest=%s:%s\n' "$name" "$(fm_provision_sha256 < "$dir/$name")"
    done <<< "$manifests"
  } | fm_provision_sha256
}

fm_provision_record_path() {  # <cache-dir> <worktree> <eco> <rel>
  local cache=$1 wt=$2 eco=$3 rel=$4 key
  key=$(printf '%s\n%s\n%s\n' "$wt" "$eco" "$rel" | fm_provision_sha256)
  printf '%s/%s.record' "$cache" "${key:0:40}"
}

fm_provision_record_get() {  # <record> <key>
  local record=$1 key=$2
  [ -f "$record" ] || return 1
  LC_ALL=C sed -n "s/^$key=//p" "$record" | head -1
}

fm_provision_record_write() {  # <record> <eco> <rel> <fingerprint> <runtime> <installer> <environment>
  local record=$1 eco=$2 rel=$3 fingerprint=$4 runtime=$5 installer=$6 environment=$7 tmp
  tmp=$(mktemp "$record.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_PROVISION_CACHE_SCHEMA"
    printf 'ecosystem=%s\n' "$eco"
    printf 'component=%s\n' "$rel"
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'runtime=%s\n' "$runtime"
    printf 'installer=%s\n' "$installer"
    printf 'environment=%s\n' "$environment"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$record"
}

# --- readiness probes -------------------------------------------------------

fm_provision_environment_signature() {  # <worktree> <eco> <rel>
  local wt=$1 eco=$2 rel=$3 dir python state
  dir=$wt/$rel
  [ "$rel" != . ] || dir=$wt
  case "$eco" in
    uv|pip)
      python="$dir/.venv/bin/python"
      [ -x "$python" ] || return 1
      state=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
        "$python" -c '
import hashlib
import pathlib
import sys

venv = pathlib.Path(sys.argv[1])
site_dirs = sorted(path for path in venv.glob("lib*/python*/site-packages") if path.is_dir())
if not site_dirs:
    raise SystemExit(1)
paths = [venv, venv / "bin", venv / "bin" / "python", *site_dirs]
config = venv / "pyvenv.cfg"
if config.exists():
    paths.append(config)
rows = []
for path in paths:
    stat = path.stat()
    digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() and not path.is_symlink() else ""
    rows.append(f"{path.relative_to(venv)}\t{stat.st_dev}\t{stat.st_ino}\t{stat.st_mode}\t{stat.st_size}\t{stat.st_mtime_ns}\t{stat.st_ctime_ns}\t{digest}")
print("\n".join(rows))
' "$dir/.venv" 2>/dev/null) || return 1
      ;;
    npm|pnpm)
      state=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
        python3 -c '
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
with (root / "package.json").open("rb") as fh:
    package = json.load(fh)
if not isinstance(package, dict):
    raise SystemExit(1)
declared = set()
for field in ("dependencies", "devDependencies"):
    values = package.get(field, {})
    if not isinstance(values, dict):
        raise SystemExit(1)
    declared.update(values)
paths = [root / "node_modules"]
bin_dir = root / "node_modules" / ".bin"
if bin_dir.exists():
    paths.append(bin_dir)
for name in sorted(declared):
    if not isinstance(name, str) or name in ("", ".", "..") or name.startswith("/"):
        raise SystemExit(1)
    package_dir = root / "node_modules" / name
    if not package_dir.is_dir() or not (package_dir / "package.json").is_file():
        raise SystemExit(1)
    paths.append(package_dir)
rows = []
for path in paths:
    stat = path.stat()
    rows.append(f"{path.relative_to(root)}\t{stat.st_dev}\t{stat.st_ino}\t{stat.st_mode}\t{stat.st_size}\t{stat.st_mtime_ns}\t{stat.st_ctime_ns}")
print("\n".join(rows))
' "$dir" 2>/dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  printf '%s' "$state" | fm_provision_sha256
}

fm_provision_declared_packages_ready() {  # <worktree> <eco> <rel>
  local wt=$1 eco=$2 rel=$3 dir python
  dir=$wt/$rel
  [ "$rel" != . ] || dir=$wt
  case "$eco" in
    uv) return 0 ;;
    pip)
      python="$dir/.venv/bin/python"
      local -a requirements=()
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        requirements+=("$dir/$name")
      done < <(fm_provision_pip_requirements "$dir")
      fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
        "$python" -c '
import pathlib
import re
import sys

venv = pathlib.Path(sys.argv[1])
site_dirs = [path for path in venv.glob("lib*/python*/site-packages") if path.is_dir()]
pattern = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^]]+\])?(?:\s*@\s*\S+|\s*(?:===|==|~=|!=|<=|>=|<|>).*)?$")
declared = set()
for requirement_file in sys.argv[2:]:
    for raw in pathlib.Path(requirement_file).read_text(errors="strict").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.endswith("\\"):
            raise SystemExit(1)
        line = line.split(" ;", 1)[0].strip()
        match = pattern.fullmatch(line)
        if not match:
            raise SystemExit(1)
        declared.add(match.group(1))
for name in declared:
    normalized = re.sub(r"[-_.]+", "_", name).lower()
    found = any(
        (candidate / "METADATA").is_file()
        for site_dir in site_dirs
        for candidate in site_dir.glob(f"{normalized}-*.dist-info")
    )
    if not found:
        raise SystemExit(1)
' "$dir/.venv" "${requirements[@]}" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

# The installed environment must actually work, not merely exist. A pool slot
# keeps ignored directories across leases, and a previous agent may have removed
# or broken them; a fingerprint alone would then report a false cache hit.
fm_provision_probe() {  # <worktree> <eco> <rel> <log> <runtime> <environment> <phase>
  local wt=$1 eco=$2 rel=$3 log=$4 runtime=$5 environment=$6 phase=$7 dir python actual current
  dir=$wt/$rel
  [ "$rel" != . ] || dir=$wt
  case "$eco" in
    uv|pip)
      python="$dir/.venv/bin/python"
      [ -x "$python" ] || return 1
      actual=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
        "$python" -c 'import sys; sys.stdout.write("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) || return 1
      [ -n "$actual" ] && [ "$actual" = "$runtime" ] || return 1
      fm_provision_run_logged "$FM_PROVISION_PROBE_TIMEOUT" "$dir" "$log" \
        uv pip check --python "$python" || return 1
      ;;
    npm|pnpm)
      [ -d "$dir/node_modules" ] || return 1
      case "$eco" in
        npm) [ -f "$dir/node_modules/.package-lock.json" ] || return 1 ;;
        pnpm) [ -f "$dir/node_modules/.modules.yaml" ] || return 1 ;;
      esac
      actual=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
        node -p 'process.versions.node' 2>/dev/null) || return 1
      [ -n "$actual" ] && [ "$actual" = "$runtime" ] || return 1
      ;;
    *) return 1 ;;
  esac
  if [ "$phase" = cache ]; then
    current=$(fm_provision_environment_signature "$wt" "$eco" "$rel") || return 1
    [ -n "$environment" ] && [ "$current" = "$environment" ] || return 1
    if [ "$eco" = pip ]; then
      fm_provision_declared_packages_ready "$wt" "$eco" "$rel" || return 1
    fi
  else
    [ -n "$environment" ] || return 1
  fi
  return 0
}

# --- installs ---------------------------------------------------------------

fm_provision_install() {  # <worktree> <eco> <rel> <log>
  local wt=$1 eco=$2 rel=$3 log=$4 dir name
  dir=$wt/$rel
  [ "$rel" != . ] || dir=$wt
  case "$eco" in
    uv)
      # --frozen installs the lock exactly as committed and never rewrites it,
      # so provisioning cannot dirty the worktree the freshness proof and
      # teardown both require to stay clean. A uv workspace has exactly one
      # uv.lock and one .venv at its root, and a plain sync there installs only
      # the root package - a lane could not then run a member's checks - so a
      # declared workspace syncs every member. Non-workspace projects keep the
      # plain form, so they carry no uv-version floor for --all-packages.
      local workspace_info
      local -a sync_args=(sync --frozen)
      workspace_info=$(fm_provision_uv_workspace_info "$dir") || return
      if [ "${workspace_info%%$'\n'*}" = workspace ]; then
        sync_args+=(--all-packages)
      fi
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        env -u UV_NO_DEV -u UV_ONLY_DEV -u UV_NO_DEFAULT_GROUPS \
        -u UV_NO_GROUP -u UV_ONLY_GROUP uv "${sync_args[@]}" || return $?
      ;;
    pip)
      local -a args=(pip install --python .venv/bin/python)
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        uv venv --clear .venv || return $?
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        args+=(-r "$name")
      done < <(fm_provision_pip_requirements "$dir")
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        uv "${args[@]}" || return $?
      ;;
    npm)
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        npm ci --include=dev || return $?
      ;;
    pnpm)
      fm_provision_run_logged "$FM_PROVISION_INSTALL_TIMEOUT" "$dir" "$log" \
        pnpm install --frozen-lockfile --prod=false || return $?
      ;;
    *) return 1 ;;
  esac
  return 0
}

# The ignored directory an ecosystem installs into, relative to the worktree.
fm_provision_artifact_path() {  # <eco> <rel>
  local eco=$1 rel=$2 name
  case "$eco" in
    uv|pip) name=.venv ;;
    npm|pnpm) name=node_modules ;;
    *) return 1 ;;
  esac
  if [ "$rel" = . ]; then
    printf '/%s/' "$name"
  else
    printf '/%s/%s/' "$rel" "$name"
  fi
}

fm_provision_fail() {  # <message>
  echo "error: worktree provisioning failed: $1" >&2
  echo "       a lane launched here could not run this project's own checks, so the spawn is refused." >&2
  echo "       Disable provisioning for this home with config/worktree-provision=off, or for one spawn with --no-provision." >&2
  return 1
}

# --- entry point ------------------------------------------------------------

# Provision every component the worktree declares. Prints per-component
# progress to stderr, appends all installer output to <log>, and sets
# FM_PROVISION_SUMMARY (the compact task-metadata value), FM_PROVISION_EXCLUDES
# (newline-separated ignored paths the caller should exclude from git's view),
# and FM_PROVISION_PATH_PREFIX (a PATH prefix pinning a declared Node runtime).
# Returns 0 on success or a clean no-op, non-zero when the spawn must refuse.
fm_provision_worktree() {  # <worktree> <cache-dir> <log>
  local wt=$1 cache=$2 log=$3
  local eco rel dir line record fingerprint recorded runtime installer environment artifact
  local declared_major pinned_major='' pinned_bin='' rc=0 state
  local -a components=() results=()

  FM_PROVISION_SUMMARY=none
  FM_PROVISION_PATH_PREFIX=
  FM_PROVISION_EXCLUDES=

  [ -d "$wt" ] || { fm_provision_fail "worktree $wt is not a directory"; return 1; }

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    components+=("$line")
  done < <(fm_provision_detect "$wt")

  if [ "${#components[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "${#components[@]}" -gt "$FM_PROVISION_MAX_COMPONENTS" ]; then
    fm_provision_fail "detected ${#components[@]} dependency components under $wt, above the FM_PROVISION_MAX_COMPONENTS limit of $FM_PROVISION_MAX_COMPONENTS"
    return 1
  fi
  if [ "$(fm_provision_bound_kind)" = none ]; then
    fm_provision_fail "no bounded-execution mechanism (timeout, gtimeout, or perl) is available, so an install could not be prevented from wedging the spawn"
    return 1
  fi

  # Refuse recognized-but-unsupported package managers before installing
  # anything, so a partially provisioned worktree is never left behind.
  for line in "${components[@]}"; do
    eco=${line%% *}
    rel=${line#* }
    case "$eco" in
      uv|pip|npm|pnpm) ;;
      *)
        fm_provision_fail "$rel declares a $eco lockfile, which this firstmate has no verified install command for"
        return 1
        ;;
    esac
    # Every Python readiness probe reads <component>/.venv. An ambient
    # UV_PROJECT_ENVIRONMENT would move uv's environment somewhere the probe
    # cannot see, which would silently degrade a cache hit into a false one.
    if [ "$eco" = uv ] && [ -n "${UV_PROJECT_ENVIRONMENT:-}" ] \
      && [ "$UV_PROJECT_ENVIRONMENT" != .venv ]; then
      fm_provision_fail "UV_PROJECT_ENVIRONMENT is set to '$UV_PROJECT_ENVIRONMENT', so the environment for $rel would not be provable at $rel/.venv"
      return 1
    fi
  done

  for line in "${components[@]}"; do
    eco=${line%% *}
    rel=${line#* }
    artifact=$(fm_provision_artifact_path "$eco" "$rel") || return 1
    FM_PROVISION_EXCLUDES="${FM_PROVISION_EXCLUDES}${artifact}"$'\n'
    if declare -F fm_provision_register_exclude >/dev/null \
      && ! fm_provision_register_exclude "$artifact"; then
      fm_provision_fail "cannot register the git exclusion for $artifact before provisioning"
      return 1
    fi
  done

  # Resolve one Node runtime for the whole worktree before any JS install, so
  # every JS component installs its native modules against the runtime the
  # crewmate will later validate with. A project that declares nothing keeps
  # the ambient runtime.
  for line in "${components[@]}"; do
    eco=${line%% *}
    rel=${line#* }
    case "$eco" in npm|pnpm) ;; *) continue ;; esac
    dir=$wt/$rel
    [ "$rel" != . ] || dir=$wt
    declared_major=$(fm_provision_declared_node_major "$dir")
    [ -n "$declared_major" ] || continue
    if [ -n "$pinned_major" ] && [ "$pinned_major" != "$declared_major" ]; then
      fm_provision_fail "components under $wt declare conflicting Node major versions ($pinned_major and $declared_major); no single runtime can serve both"
      return 1
    fi
    pinned_major=$declared_major
  done
  if [ -n "$pinned_major" ]; then
    runtime=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$wt" node -p 'process.versions.node' 2>/dev/null) || runtime=
    if [ -n "$runtime" ] && [ "${runtime%%.*}" = "$pinned_major" ]; then
      pinned_bin=
    else
      pinned_bin=$(fm_provision_find_node_bin "$pinned_major")
      if [ -z "$pinned_bin" ]; then
        fm_provision_fail "this project declares Node $pinned_major, but no Node $pinned_major runtime was found on PATH or under the standard version-manager directories (\$NVM_DIR, \$FNM_DIR, \$VOLTA_HOME, ~/.asdf)"
        return 1
      fi
      # Read by the sourcing caller (fm-spawn.sh's crew_tool_path).
      # shellcheck disable=SC2034
      FM_PROVISION_PATH_PREFIX=$pinned_bin
      PATH="$pinned_bin:$PATH"
      export PATH
      echo "fm-spawn: pinning Node $pinned_major from $pinned_bin for this worktree" >&2
    fi
  fi

  mkdir -p "$cache" || { fm_provision_fail "cannot create the provisioning cache directory $cache"; return 1; }
  : >> "$log" || { fm_provision_fail "cannot write the provisioning log $log"; return 1; }
  printf '=== provisioning %s at %s ===\n' "$wt" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$log"

  for line in "${components[@]}"; do
    eco=${line%% *}
    rel=${line#* }
    dir=$wt/$rel
    [ "$rel" != . ] || dir=$wt

    case "$eco" in
      uv|pip) installer=$(fm_provision_tool_version uv --version) || installer= ;;
      npm) installer=$(fm_provision_tool_version npm --version) || installer= ;;
      pnpm) installer=$(fm_provision_tool_version pnpm --version) || installer= ;;
    esac
    if [ -z "$installer" ]; then
      case "$eco" in
        uv|pip) fm_provision_fail "$rel is a Python project but uv is not installed; firstmate provisions Python through uv, never pip or venv" ;;
        *) fm_provision_fail "$rel needs $eco, which is not installed" ;;
      esac
      return 1
    fi

    # The runtime identity a component is fingerprinted and probed against.
    # Node's is known before installing; a virtualenv's interpreter is an
    # OUTPUT of the install (uv resolves it from the project's own
    # .python-version or requires-python), so it is recorded afterwards and the
    # probe holds the environment to it.
    case "$eco" in
      npm|pnpm)
        runtime=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" node -p 'process.versions.node' 2>/dev/null) || runtime=
        if [ -z "$runtime" ]; then
          fm_provision_fail "$rel needs node, which did not run"
          return 1
        fi
        ;;
      *) runtime= ;;
    esac

    record=$(fm_provision_record_path "$cache" "$wt" "$eco" "$rel")
    fingerprint=$(fm_provision_fingerprint "$wt" "$eco" "$rel" "$installer" "$runtime") || {
      fm_provision_fail "cannot resolve the declared manifests for the $eco component in $rel"
      return 1
    }
    recorded=$(fm_provision_record_get "$record" fingerprint 2>/dev/null || true)
    state=installed
    if [ -n "$recorded" ] && [ "$recorded" = "$fingerprint" ] \
      && [ "$(fm_provision_record_get "$record" schema 2>/dev/null || true)" = "$FM_PROVISION_CACHE_SCHEMA" ]; then
      local probe_runtime
      probe_runtime=$(fm_provision_record_get "$record" runtime 2>/dev/null || true)
      environment=$(fm_provision_record_get "$record" environment 2>/dev/null || true)
      if fm_provision_probe "$wt" "$eco" "$rel" "$log" "$probe_runtime" "$environment" cache; then
        state=cached
      fi
    fi

    if [ "$state" = installed ]; then
      echo "fm-spawn: provisioning $eco dependencies in $rel" >&2
      rc=0
      fm_provision_install "$wt" "$eco" "$rel" "$log" || rc=$?
      if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 124 ]; then
          fm_provision_fail "the $eco install in $rel exceeded its ${FM_PROVISION_INSTALL_TIMEOUT}s bound; see $log"
        else
          fm_provision_fail "the $eco install in $rel exited $rc; see $log"
        fi
        return 1
      fi
      case "$eco" in
        uv|pip)
          runtime=$(fm_provision_run_bounded "$FM_PROVISION_PROBE_TIMEOUT" "$dir" \
            "$dir/.venv/bin/python" -c 'import sys; sys.stdout.write("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) || runtime=
          if [ -z "$runtime" ]; then
            fm_provision_fail "the $eco install in $rel left no working interpreter at $rel/.venv/bin/python; see $log"
            return 1
          fi
          ;;
      esac
      environment=$(fm_provision_environment_signature "$wt" "$eco" "$rel") || environment=
      if ! fm_provision_probe "$wt" "$eco" "$rel" "$log" "$runtime" "$environment" installed; then
        fm_provision_fail "the $eco environment in $rel is not usable after installing; see $log"
        return 1
      fi
      fm_provision_record_write "$record" "$eco" "$rel" "$fingerprint" "$runtime" "$installer" "$environment" \
        || { fm_provision_fail "cannot record the provisioning fingerprint at $record"; return 1; }
    fi

    results+=("$eco:$rel=$state")
  done

  FM_PROVISION_SUMMARY=$(IFS=,; printf '%s' "${results[*]}")
  echo "fm-spawn: worktree provisioned - $FM_PROVISION_SUMMARY" >&2
  return 0
}
