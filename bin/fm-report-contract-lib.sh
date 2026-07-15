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
