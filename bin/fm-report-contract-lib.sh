#!/usr/bin/env bash
# Render the single completion-report prompt contract shared by ship briefs and
# managed continuation prompts.
# The durable publication and storage contract lives in docs/report-stack.md.

fm_completion_report_contract() {  # <data-dir> <task-id>
  local data=$1 task=$2
  printf '%s\n' \
    '# Completion report' \
    "Before the final \`done:\` status, write \`$data/$task/completion.md\` with these sections: Summary, What changed, Verification, Visual evidence, Artifacts, and Follow-ups." \
    'Make it stand alone for the captain: explain the outcome, name important files or links, record the validation performed, and call out remaining risk or decisions.' \
    "Put screenshots, diagrams, or other visual artifacts under \`$data/$task/visuals/\` and reference them from the report when they materially help review." \
    "If review or the no-mistakes pipeline changes the implementation after the report is first written, refresh the report before the later final \`done:\` status." \
    'These completion-report paths and the status file are the only authorized writes outside the worktree.'
}

fm_completion_report_contract_ensure() (  # <data-dir> <task-id> <brief>
  local data=$1 task=$2 brief=$3 data_real task_real brief_parent brief_target
  local source_identity current_identity mode temp=

  data_real=$(cd "$data" 2>/dev/null && pwd -P) || {
    echo "error: completion-report data directory is unavailable: $data" >&2
    return 1
  }
  task_real=$(cd "$data/$task" 2>/dev/null && pwd -P) || {
    echo "error: completion-report task directory is unavailable: $data/$task" >&2
    return 1
  }
  if [ "$task_real" != "$data_real/$task" ]; then
    echo "error: completion-report task directory must resolve directly inside $data_real: $data/$task" >&2
    return 1
  fi
  brief_parent=$(cd "$(dirname "$brief")" 2>/dev/null && pwd -P) || {
    echo "error: task brief parent is unavailable: $brief" >&2
    return 1
  }
  brief_target="$task_real/$(basename "$brief")"
  if [ "$brief_parent" != "$task_real" ] || [ -L "$brief_target" ] || [ ! -f "$brief_target" ]; then
    echo "error: task brief must be a real regular file inside $task_real: $brief" >&2
    return 1
  fi
  if grep -q '^# Completion report$' "$brief_target"; then
    return 0
  fi

  if source_identity=$(stat -f '%d:%i:%z:%m' "$brief_target" 2>/dev/null); then
    mode=$(stat -f '%Lp' "$brief_target")
  else
    source_identity=$(stat -c '%d:%i:%s:%Y' "$brief_target") || return 1
    mode=$(stat -c '%a' "$brief_target") || return 1
  fi
  temp=$(mktemp "$task_real/.brief-contract.XXXXXX") || {
    echo "error: could not stage the completion-report contract inside $task_real" >&2
    return 1
  }
  trap '[ -z "$temp" ] || rm -f -- "$temp"' EXIT HUP INT TERM
  if ! cat "$brief_target" > "$temp"; then
    echo "error: could not read task brief for completion-report upgrade: $brief" >&2
    return 1
  fi
  chmod "$mode" "$temp" || return 1
  {
    printf '\n'
    fm_completion_report_contract "$data" "$task"
  } >> "$temp" || return 1

  if [ -L "$brief_target" ] || [ ! -f "$brief_target" ]; then
    echo "error: task brief changed during completion-report upgrade: $brief" >&2
    return 1
  fi
  if current_identity=$(stat -f '%d:%i:%z:%m' "$brief_target" 2>/dev/null); then
    :
  else
    current_identity=$(stat -c '%d:%i:%s:%Y' "$brief_target") || return 1
  fi
  if [ "$current_identity" != "$source_identity" ]; then
    echo "error: task brief changed during completion-report upgrade: $brief" >&2
    return 1
  fi
  mv -f -- "$temp" "$brief_target" || return 1
  temp=
)
