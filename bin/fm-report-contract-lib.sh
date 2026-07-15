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

fm_completion_report_contract_present() {  # <brief>
  fm_completion_report_contract_file present "$1"
}

fm_completion_report_contract_ensure() (  # <data-dir> <task-id> <brief>
  local data=$1 task=$2 brief=$3 data_real task_real brief_parent brief_target
  local contract

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
  contract=$(fm_completion_report_contract "$data" "$task") || return 1
  FM_COMPLETION_REPORT_CONTRACT=$contract fm_completion_report_contract_file ensure "$brief_target"
)

fm_completion_report_contract_file() {  # <present|ensure> <brief>
  node - "$1" "$2" <<'JS'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const action = process.argv[2];
const brief = process.argv[3];
let source;
let staged;

function contractPresent(markdown) {
  let fenceCharacter = '';
  let fenceLength = 0;
  for (const rawLine of markdown.split(/\r?\n/)) {
    const marker = rawLine.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (fenceCharacter) {
      if (marker && marker[1][0] === fenceCharacter && marker[1].length >= fenceLength && /^\s*$/.test(marker[2])) {
        fenceCharacter = '';
        fenceLength = 0;
      }
      continue;
    }
    if (marker && !(marker[1][0] === '`' && marker[2].includes('`'))) {
      fenceCharacter = marker[1][0];
      fenceLength = marker[1].length;
      continue;
    }
    if (rawLine.replace(/^ {0,3}/, '') === '# Completion report') return true;
  }
  return false;
}

function sameSnapshot(left, right) {
  return left.dev === right.dev && left.ino === right.ino && left.size === right.size
    && left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs;
}

try {
  source = fs.openSync(brief, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  const initial = fs.fstatSync(source, { bigint: true });
  if (!initial.isFile()) throw new Error('source is not a regular file');
  const content = fs.readFileSync(source);
  if (contractPresent(content.toString('utf8'))) {
    process.exitCode = 0;
  } else if (action === 'present') {
    process.exitCode = 1;
  } else if (action === 'ensure') {
    const contract = process.env.FM_COMPLETION_REPORT_CONTRACT;
    if (!contract) throw new Error('completion-report contract is empty');
    staged = path.join(path.dirname(brief), `.brief-contract.${process.pid}.${crypto.randomBytes(8).toString('hex')}`);
    const output = Buffer.concat([content, Buffer.from(`\n${contract}\n`)]);
    const destination = fs.openSync(staged, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, Number(initial.mode & 0o7777n));
    try {
      fs.writeFileSync(destination, output);
      fs.fchmodSync(destination, Number(initial.mode & 0o7777n));
      fs.fsyncSync(destination);
    } finally {
      fs.closeSync(destination);
    }
    const finalSource = fs.fstatSync(source, { bigint: true });
    const currentPath = fs.lstatSync(brief, { bigint: true });
    if (!sameSnapshot(initial, finalSource) || !currentPath.isFile()
      || currentPath.dev !== finalSource.dev || currentPath.ino !== finalSource.ino) {
      throw new Error('task brief changed during completion-report upgrade');
    }
    fs.renameSync(staged, brief);
    staged = undefined;
  } else {
    throw new Error(`unknown completion-report brief action: ${action}`);
  }
} catch (error) {
  console.error(`error: completion-report brief transaction failed for ${brief}: ${error.message}`);
  process.exitCode = 1;
} finally {
  if (source !== undefined) fs.closeSync(source);
  if (staged !== undefined) {
    try { fs.unlinkSync(staged); } catch {}
  }
}
JS
}
