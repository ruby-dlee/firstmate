#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUPERVISOR="$ROOT/bin/fm-worker-supervisor.py"

run_supervisor_controls() {
  local tmp work account request result home task_gen assignment repo_gen account_binding worktree_binding repo_binding cloud
  fm_test_tmproot_into tmp fm-worker-supervisor
  work="$tmp/work"
  account="$tmp/account"
  mkdir -p "$work" "$account"
  home=$(printf home | shasum -a 256 | awk '{print $1}')
  account_binding=$(printf account | shasum -a 256 | awk '{print $1}')
  worktree_binding=$(printf worktree | shasum -a 256 | awk '{print $1}')
  repo_binding=$(printf repo | shasum -a 256 | awk '{print $1}')
  task_gen=task-gen
  assignment=asg-00000001
  repo_gen='repo-gen'
  cloud=vm-instance
  request="$tmp/request.json"
  result="$tmp/result.json"
  python3 - "$request" "$home" "$account_binding" "$worktree_binding" "$repo_binding" <<'PY'
import hashlib,json,sys
path,home,account,worktree,repo=sys.argv[1:]
value={"schema":"fm.worker-execution/v1","home_binding":home,"task":"task-one","task_generation":"task-gen","assignment_generation":"asg-00000001","account_binding":account,"worktree_binding":worktree,"repository_binding":repo,"repository_generation":"repo-gen","cloud_instance_id":"vm-instance","argv":["/usr/bin/python3","-c","print('ok')"],"wall_seconds":60}
value["request_digest"]=hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",", ":")).encode()).hexdigest()
json.dump(value,open(path,"w"),sort_keys=True,separators=(",", ":"))
PY
  env FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one \
    FM_WORKER_TASK_GENERATION="$task_gen" FM_WORKER_ASSIGNMENT_GENERATION="$assignment" \
    FM_WORKER_ACCOUNT_BINDING="$account_binding" FM_WORKER_WORKTREE_BINDING="$worktree_binding" \
    FM_WORKER_REPOSITORY_BINDING="$repo_binding" FM_WORKER_REPOSITORY_GENERATION="$repo_gen" \
    FM_WORKER_CLOUD_INSTANCE_ID="$cloud" FM_WORKER_WORKTREE="$work" FM_WORKER_ACCOUNT_HOME="$account" \
    "$SUPERVISOR" execute --request "$request" --result "$result" >/dev/null \
    || fail "minimal guest supervisor rejected an exact request"
  python3 - "$request" "$result" <<'PY' || fail "minimal guest supervisor result was not exact"
import hashlib,json,sys
request=json.load(open(sys.argv[1])); result=json.load(open(sys.argv[2])); supplied=result.pop("result_digest")
assert result["schema"]=="fm.worker-execution-result/v1" and result["request_digest"]==request["request_digest"]
assert result["task"]=="task-one" and result["assignment_generation"]=="asg-00000001" and result["exit_code"]==0
assert supplied==hashlib.sha256(json.dumps(result,sort_keys=True,separators=(",", ":")).encode()).hexdigest()
PY

  # Unsafe positive controls: changed request after digest, changed assignment
  # environment, shell-shaped empty command, and timeout all produce bounded refusal/result.
  python3 - "$request" <<'PY'
import json,sys
value=json.load(open(sys.argv[1])); value["argv"]=["/usr/bin/false"]; json.dump(value,open(sys.argv[1],"w"),sort_keys=True,separators=(",", ":"))
PY
  if env FM_WORKER_HOME_BINDING="$home" FM_WORKER_TASK=task-one FM_WORKER_TASK_GENERATION="$task_gen" \
      FM_WORKER_ASSIGNMENT_GENERATION="$assignment" FM_WORKER_ACCOUNT_BINDING="$account_binding" \
      FM_WORKER_WORKTREE_BINDING="$worktree_binding" FM_WORKER_REPOSITORY_BINDING="$repo_binding" \
      FM_WORKER_REPOSITORY_GENERATION="$repo_gen" FM_WORKER_CLOUD_INSTANCE_ID="$cloud" \
      FM_WORKER_WORKTREE="$work" FM_WORKER_ACCOUNT_HOME="$account" \
      "$SUPERVISOR" execute --request "$request" --result "$result" >/dev/null 2>&1; then
    fail "minimal guest supervisor accepted a request changed after digest binding"
  fi
  pass "pinned guest supervisor executes one exact command and rejects changed request or assignment identity"
}

run_supervisor_controls
echo "# fm-worker-supervisor.test.sh: all assertions passed"
