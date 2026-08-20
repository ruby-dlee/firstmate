#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Hermetic coverage for the cloud secondmate compartment lane (R2/R3 design C
# item 4): bin/fm-secondmate-cloud-monitor.sh + .py, the fm-send compartment
# inbox routing, and the fm-spawn secondmate gate behind
# FM_SPAWN_SECONDMATE_CLOUD.
#
# The lifecycle CLI is a FIXTURE here (argv captured, canned JSON returned,
# blob transfers modeled against a local store directory): the real
# fm-worker-lifecycle.sh message lane lands in a sibling PR, and the real
# wrapper must never run Azure operations from a test. The chain the monitor
# verifies is REAL: every outbox fixture is produced by the real
# bin/fm-secondmate-session.py against the store, so the real producer feeds
# the real verifier and a contract drift between them goes red here.

MONITOR="$ROOT/bin/fm-secondmate-cloud-monitor.sh"
RUNNER="$ROOT/bin/fm-secondmate-session.py"
SEND="$ROOT/bin/fm-send.sh"
fm_git_identity fmtest fmtest@example.invalid
fm_test_tmproot_into TMP_ROOT fm-secondmate-cloud-monitor

ID=cmp-task
GEN=gen-one
ASSIGNMENT=asg-00000001
SUB=11111111-1111-4111-8111-111111111111

# --- fixture: the lifecycle CLI seam -----------------------------------------
#
# Records every invocation (one line, unit-separator-joined argv) and models
# exactly the three commands the monitor drives. execute returns a canned
# bounded result at once; message-put content-addresses the file into the
# store's session/in/; message-collect copies the store's session/out/ into
# the output dir and reports the paginated summary shape (cursor + more).
write_fixture_lifecycle() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
LOG=${FM_FIXTURE_LIFECYCLE_LOG:?}
STORE=${FM_FIXTURE_STORE:?}
{
  first=1
  for arg in "$@"; do
    if [ "$first" = 1 ]; then printf '%s' "$arg"; first=0; else printf '\x1f%s' "$arg"; fi
  done
  printf '\n'
} >> "$LOG"
command=$1
shift
case "$command" in
  execute)
    if [ -n "${FM_FIXTURE_EXECUTE_HOLD:-}" ]; then
      while [ ! -e "$FM_FIXTURE_EXECUTE_HOLD" ]; do sleep 0.05; done
    fi
    printf '{"schema":"fm.worker-execution-result/v1","exit_code":0,"timed_out":false}\n'
    ;;
  message-put)
    file=
    prev=
    for arg in "$@"; do
      [ "$prev" = --file ] && file=$arg
      prev=$arg
    done
    [ -n "$file" ] || { echo 'fixture: message-put without --file' >&2; exit 2; }
    digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$file")
    bytes=$(wc -c < "$file" | tr -d '[:space:]')
    target="$STORE/session/in/$digest.json"
    replayed=false
    if [ -e "$target" ]; then
      replayed=true
    else
      mkdir -p "$STORE/session/in"
      cp "$file" "$target"
    fi
    printf '{"blob_name":"session/in/%s.json","bytes":%s,"replayed":%s,"sha256":"%s"}\n' \
      "$digest" "$bytes" "$replayed" "$digest"
    ;;
  message-collect)
    outdir=
    prev=
    for arg in "$@"; do
      [ "$prev" = --output-dir ] && outdir=$arg
      prev=$arg
    done
    [ -n "$outdir" ] || { echo 'fixture: message-collect without --output-dir' >&2; exit 2; }
    cursor=
    if [ -d "$STORE/session/out" ]; then
      for blob in "$STORE/session/out"/*; do
        [ -e "$blob" ] || continue
        name=${blob##*/}
        [ -e "$outdir/$name" ] || cp "$blob" "$outdir/$name"
        cursor=$name
      done
    fi
    if [ -n "$cursor" ]; then
      printf '{"fetched":[],"skipped":[],"cursor":"%s","more":false}\n' "$cursor"
    else
      printf '{"fetched":[],"skipped":[],"cursor":null,"more":false}\n'
    fi
    ;;
  *)
    echo "fixture: unsupported lifecycle command $command" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$1"
}

# --- fixture: one compartment world ------------------------------------------
#
# Globals set by make_world: WORLD HOME_DIR STATE_DIR STORE LC_LOG PANE_LOG
# LIFECYCLE_FIXTURE LANDING ORIGIN GUEST_REPO GUEST_STATE BASE FAKE_PI TURN_LOG
make_world() {
  local name=$1
  WORLD="$TMP_ROOT/$name"
  HOME_DIR="$WORLD/home"
  STATE_DIR="$HOME_DIR/state"
  STORE="$WORLD/store"
  LC_LOG="$WORLD/lifecycle.log"
  PANE_LOG="$WORLD/pane.log"
  LIFECYCLE_FIXTURE="$WORLD/fixture-lifecycle.sh"
  ORIGIN="$WORLD/origin"
  LANDING="$WORLD/landing"
  GUEST_REPO="$WORLD/guest-repo"
  GUEST_STATE="$WORLD/guest-state"
  FAKE_PI="$WORLD/fake-pi"
  TURN_LOG="$WORLD/turns.log"
  mkdir -p "$STATE_DIR/azure-workers" "$STORE/session/in" "$STORE/session/out" \
    "$STATE_DIR/$ID.cloud-payload" "$STATE_DIR/$ID.cloud-account"
  : > "$LC_LOG"
  : > "$TURN_LOG"
  printf 'staged\n' > "$STATE_DIR/$ID.cloud-payload/repo.bundle"
  printf 'staged\n' > "$STATE_DIR/$ID.cloud-account/auth.json"
  write_fixture_lifecycle "$LIFECYCLE_FIXTURE"
  fm_git_init_commit "$ORIGIN"
  git clone --quiet "$ORIGIN" "$LANDING"
  git clone --quiet "$ORIGIN" "$GUEST_REPO"
  BASE=$(git -C "$LANDING" rev-parse HEAD)
  printf '%s\n' "$LANDING" > "$STATE_DIR/$ID.cloud-worktree"
  # Persisted compartment environment: identities and durable leg config,
  # exactly what the gated spawn writes. Small legs keep the suite fast.
  {
    printf 'export FM_AZURE_SUBSCRIPTION_ID=%s\n' "$SUB"
    printf 'export FM_AZURE_STORAGE_NAME=stfixture\n'
    printf 'export FM_SECONDMATE_LEG_SECONDS=120\n'
    printf 'export FM_SECONDMATE_POLL_SECONDS=5\n'
    printf 'export FM_SECONDMATE_IDLE_SECONDS=600\n'
  } > "$STATE_DIR/$ID.cloud-env"
  write_controller assigned
  cat > "$FAKE_PI" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_PI_LOG"
last=
for arg in "$@"; do last=$arg; done
case "${FM_FAKE_PI_MODE:-reply}" in
  reply) printf 'canned-reply:%s' "$last" ;;
  commit)
    echo turn >> turn.txt
    git add turn.txt
    git -c user.name='Fixture Pi' -c user.email='pi@example.invalid' commit -qm 'fixture turn'
    printf 'committed'
    ;;
esac
SH
  chmod +x "$FAKE_PI"
}

write_controller() {  # <status>
  python3 - "$STATE_DIR/azure-workers/controller.json" "$ID" "$GEN" "$ASSIGNMENT" "$BASE" "$1" <<'PY'
import json
import sys

path, task, generation, assignment, base, status = sys.argv[1:]
key = "{}@{}".format(task, generation)
state = {"queue": {key: {"task": task, "task_generation": generation, "status": status, "role": "secondmate"}}, "workers": {}}
if status == "assigned":
    state["queue"][key]["assignment_generation"] = assignment
    state["queue"][key]["slot"] = 3
    state["workers"]["3"] = {
        "slot": 3, "role": "secondmate", "assignment_generation": assignment,
        "bindings": {"repository_generation": base},
    }
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
}

# run_guest_leg [VAR=value ...] - one REAL runner leg against the store, so
# the outbox chain the monitor verifies is produced by the real producer.
run_guest_leg() {
  perl -e 'alarm 120; exec @ARGV or die "exec failed: $!"' -- \
    env FM_WORKER_TASK="$ID" FM_WORKER_TASK_GENERATION="$GEN" \
    FM_WORKER_ASSIGNMENT_GENERATION="$ASSIGNMENT" \
    FM_WORKER_REPOSITORY_GENERATION="$BASE" \
    FM_SECONDMATE_BLOB_DIR="$STORE" FM_SECONDMATE_STATE_DIR="$GUEST_STATE" \
    FM_SECONDMATE_REPO_DIR="$GUEST_REPO" FM_SECONDMATE_PI_BIN="$FAKE_PI" \
    FM_FAKE_PI_LOG="$TURN_LOG" \
    "$@" python3 "$RUNNER"
}

put_guest_inbox() {  # '<json>' - store one canonical inbox message
  python3 - "$STORE" "$1" <<'PY'
import hashlib, json, pathlib, sys
store, raw = sys.argv[1:]
body = json.dumps(json.loads(raw), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
digest = hashlib.sha256(body).hexdigest()
target = pathlib.Path(store) / "session" / "in" / (digest + ".json")
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(body)
print(digest)
PY
}

MONITOR_PID=
start_monitor() {  # [VAR=value ...]
  perl -e 'alarm 90; exec @ARGV or die "exec failed: $!"' -- \
    env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SECONDMATE_LIFECYCLE_BIN="$LIFECYCLE_FIXTURE" \
    FM_SECONDMATE_MONITOR_INTERVAL_SECONDS=1 \
    FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" FM_FIXTURE_STORE="$STORE" \
    "$@" "$MONITOR" "$ID" "$GEN" >> "$PANE_LOG" 2>&1 &
  MONITOR_PID=$!
}

stop_monitor() {
  [ -z "$MONITOR_PID" ] || kill "$MONITOR_PID" 2>/dev/null || true
  [ -z "$MONITOR_PID" ] || wait "$MONITOR_PID" 2>/dev/null
  MONITOR_PID=
}

wait_for() {  # <description> <check-command...>
  local description=$1 limit i=0
  shift
  limit=$(fm_test_liveness_iterations 1 0.2)
  while [ "$i" -lt "$limit" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    if [ -n "$MONITOR_PID" ] && ! kill -0 "$MONITOR_PID" 2>/dev/null; then
      # The monitor may have exited legitimately (terminal status); give the
      # check one final chance against the settled state.
      "$@" >/dev/null 2>&1 && return 0
      fail "monitor exited before: $description (pane: $(tail -5 "$PANE_LOG" 2>/dev/null))"
    fi
    sleep 0.2
    i=$((i + 1))
  done
  fail "timed out waiting for: $description (pane: $(tail -5 "$PANE_LOG" 2>/dev/null); lifecycle: $(tail -3 "$LC_LOG" 2>/dev/null))"
}

grep_lc() { grep -c "$1" "$LC_LOG" 2>/dev/null | tr -d '[:space:]'; }

both_envelopes_relayed() {
  [ "$(ls "$STATE_DIR/$ID.cloud-inbox/.relayed" 2>/dev/null | wc -l | tr -d '[:space:]')" -ge 2 ]
}

lc_line() {  # <n> - nth lifecycle invocation, unit separators shown as \x1f
  sed -n "${1}p" "$LC_LOG"
}

leg_entry_argv() {  # <n> - the exact leg entrypoint string the monitor builds
  printf 'FM_SECONDMATE_LEG=%s python3 /mnt/task/.fm-task/fm-secondmate-session.py --task %s --task-generation %s --assignment-generation %s --repository-generation %s --pi-ext /mnt/task/.fm-task/fm-secondmate-spawn.pi-ext.ts --storage-account stfixture --container worker-state-03 --leg-seconds 120 --poll-seconds 5 --idle-seconds 600' \
    "$1" "$ID" "$GEN" "$ASSIGNMENT" "$BASE"
}

# --- units --------------------------------------------------------------------

test_leg1_carries_staging_and_leg2_is_manifest_free_golden() {
  make_world leg-chain
  # A real wall-ended leg: tiny leg budget, no inbox traffic, so the runner
  # exits reason=wall with a verified summary (legs_completed=1).
  run_guest_leg FM_SECONDMATE_LEG_SECONDS=2 >/dev/null 2>&1 \
    || fail "guest wall leg did not exit cleanly"
  start_monitor
  wait_for "leg 2 dispatch after the wall summary" grep -q $'execute\x1f.*FM_SECONDMATE_LEG=2' "$LC_LOG"
  stop_monitor
  local line1 line2 expected1 expected2
  line1=$(grep $'^execute\x1f' "$LC_LOG" | sed -n 1p)
  line2=$(grep $'^execute\x1f' "$LC_LOG" | sed -n 2p)
  expected1=$(printf 'execute\x1f--task\x1f%s\x1f--task-generation\x1f%s\x1f--assignment-generation\x1f%s\x1f--wall-seconds\x1f1920\x1f--payload-dir\x1f%s\x1f--account-dir\x1f%s\x1f--confirm-execute\x1f--confirm-subscription\x1f%s\x1f--\x1f/bin/bash\x1f-lc\x1f%s' \
    "$ID" "$GEN" "$ASSIGNMENT" "$STATE_DIR/$ID.cloud-payload" "$STATE_DIR/$ID.cloud-account" "$SUB" "$(leg_entry_argv 1)")
  [ "$line1" = "$expected1" ] || fail "leg 1 dispatch argv is not the staged shape:
got:      $(printf '%s' "$line1" | tr '\037' '|')
expected: $(printf '%s' "$expected1" | tr '\037' '|')"
  # THE GOLDEN (the rmtree regression guard): the leg 2+ request argv is
  # byte-exact and carries NEITHER --payload-dir NOR --account-dir, so it
  # hits the supervisor's staging-skip branch instead of rmtree-ing the
  # compartment repository. wall 1920 = leg 120 + finish-leg budget 1800.
  expected2=$(printf 'execute\x1f--task\x1f%s\x1f--task-generation\x1f%s\x1f--assignment-generation\x1f%s\x1f--wall-seconds\x1f1920\x1f--confirm-execute\x1f--confirm-subscription\x1f%s\x1f--\x1f/bin/bash\x1f-lc\x1f%s' \
    "$ID" "$GEN" "$ASSIGNMENT" "$SUB" "$(leg_entry_argv 2)")
  [ "$line2" = "$expected2" ] || fail "GOLDEN: leg 2 dispatch argv is not byte-exact manifest-free:
got:      $(printf '%s' "$line2" | tr '\037' '|')
expected: $(printf '%s' "$expected2" | tr '\037' '|')"
  case "$line2" in
    *payload-dir*|*account-dir*) fail "leg 2 dispatch carries staging manifests (the rmtree regression)" ;;
  esac
  assert_present "$STATE_DIR/$ID.cloud-secondmate-leg-0001.dispatched" "leg 1 O_EXCL marker missing"
  assert_present "$STATE_DIR/$ID.cloud-secondmate-leg-0002.dispatched" "leg 2 O_EXCL marker missing"
  assert_present "$STATE_DIR/$ID.cloud-secondmate-first-dispatch" "TTL anchor missing"
  pass "leg 1 carries the staging pair; leg 2 argv is byte-exact manifest-free (rmtree guard)"
}

test_o_excl_guard_prevents_double_dispatch() {
  make_world double-dispatch
  # No outbox traffic at all: leg 1 result lands but no summary ever appears,
  # so renewal stays withheld and leg 1 is the only dispatch either racing
  # monitor could make.
  local second_pane="$WORLD/pane-2.log" second_pid
  start_monitor
  perl -e 'alarm 90; exec @ARGV or die "exec failed: $!"' -- \
    env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SECONDMATE_LIFECYCLE_BIN="$LIFECYCLE_FIXTURE" \
    FM_SECONDMATE_MONITOR_INTERVAL_SECONDS=1 \
    FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" FM_FIXTURE_STORE="$STORE" \
    "$MONITOR" "$ID" "$GEN" >> "$second_pane" 2>&1 &
  second_pid=$!
  wait_for "leg 1 dispatch" grep -q $'execute\x1f' "$LC_LOG"
  # Let both monitors run several further iterations against the same state.
  sleep 3
  kill "$second_pid" 2>/dev/null || true
  wait "$second_pid" 2>/dev/null
  stop_monitor
  local executes
  executes=$(grep_lc $'^execute\x1f')
  [ "$executes" = 1 ] || fail "two racing monitors dispatched $executes executes for one leg (O_EXCL guard broken)"
  pass "two racing monitors dispatch exactly one leg execute (O_EXCL)"
}

test_inbox_relay_is_content_addressed_and_replay_safe() {
  make_world inbox-relay
  # fm-send's envelope shape, written directly (the fm-send routing unit
  # covers the real writer): canonical JSON named <seq>-<sha256>.json.
  mkdir -p "$STATE_DIR/$ID.cloud-inbox"
  python3 - "$STATE_DIR/$ID.cloud-inbox" "$ASSIGNMENT" <<'PY'
import hashlib, json, pathlib, sys
inbox, assignment = sys.argv[1:]
for sequence, text in ((1, "first captain note"), (2, "second captain note")):
    message = {"kind": "fm.secondmate-message/v1", "text": text, "nonce": "{}/{:08d}".format(assignment, sequence)}
    body = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    name = "{:08d}-{}.json".format(sequence, hashlib.sha256(body).hexdigest())
    (pathlib.Path(inbox) / name).write_bytes(body)
PY
  start_monitor
  wait_for "both envelopes relayed" both_envelopes_relayed
  stop_monitor
  local puts
  puts=$(grep_lc $'^message-put\x1f')
  [ "$puts" = 2 ] || fail "expected exactly 2 message-put relays, saw $puts"
  # message-put argv names the envelope file; the store blob name digest must
  # equal the local file digest (content addressing end to end).
  python3 - "$STATE_DIR/$ID.cloud-inbox" "$STORE" <<'PY' || fail "store blobs do not content-address the relayed envelopes"
import hashlib, pathlib, re, sys
inbox, store = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
locals_ = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inbox.glob("[0-9]*.json")}
assert len(locals_) == 2, locals_
for name, digest in locals_.items():
    assert re.fullmatch(r"[0-9]{8}-" + digest + r"\.json", name), (name, digest)
    blob = store / "session" / "in" / (digest + ".json")
    assert blob.is_file(), blob
    assert hashlib.sha256(blob.read_bytes()).hexdigest() == digest
PY
  # Replay: a fresh monitor over the same durable state must not re-put.
  : > "$LC_LOG"
  start_monitor
  sleep 3
  stop_monitor
  puts=$(grep_lc $'^message-put\x1f')
  [ "$puts" = 0 ] || fail "a respawned monitor re-relayed already-relayed envelopes ($puts puts)"
  pass "inbox relay is content-addressed and replay-safe across monitor restarts"
}

test_verified_chain_delivers_and_close_is_terminal() {
  make_world verified-chain
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"hello compartment"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "guest close leg did not exit cleanly"
  start_monitor
  wait_for "terminal status file" test -f "$STATE_DIR/$ID.cloud-secondmate-status"
  stop_monitor
  assert_contains "$(cat "$STATE_DIR/$ID.cloud-secondmate-status")" "closed" "close summary did not record a closed terminal status"
  assert_grep 'canned-reply:hello compartment' "$PANE_LOG" "the verified reply text never reached the pane"
  assert_grep 'reason=close' "$PANE_LOG" "the close leg summary never rendered"
  # close is terminal: exactly one leg was dispatched, ever.
  [ "$(grep_lc $'^execute\x1f')" = 1 ] || fail "a closed chain dispatched more than one leg"
  assert_absent "$STATE_DIR/$ID.cloud-secondmate-leg-0002.dispatched" "a closed chain claimed a second leg"
  pass "a verified chain delivers replies to the pane and close ends the chain without renewal"
}

test_dropped_blob_refuses_whole_mailbox_and_freezes_relay() {
  make_world dropped-blob
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"turn one"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"turn two","nonce":"n2"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "guest leg did not exit cleanly"
  # Drop the MIDDLE chain entry from the store before any collection.
  local middle
  middle=$(ls "$STORE/session/out" | grep '^00000002-' | head -1)
  [ -n "$middle" ] || fail "fixture outbox lacks a second entry"
  rm "$STORE/session/out/$middle"
  # A pending captain envelope proves the inbound freeze.
  mkdir -p "$STATE_DIR/$ID.cloud-inbox"
  start_monitor
  wait_for "chain-break marker" test -f "$STATE_DIR/$ID.cloud-mailbox/.chain-break"
  # Now enqueue an envelope AFTER the break and let the monitor loop again.
  python3 - "$STATE_DIR/$ID.cloud-inbox" "$ASSIGNMENT" <<'PY'
import hashlib, json, pathlib, sys
inbox, assignment = sys.argv[1:]
message = {"kind": "fm.secondmate-message/v1", "text": "after the break", "nonce": assignment + "/00000001"}
body = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
name = "00000001-{}.json".format(hashlib.sha256(body).hexdigest())
(pathlib.Path(inbox) / name).write_bytes(body)
PY
  sleep 3
  stop_monitor
  assert_grep 'SECONDMATE MAILBOX REFUSED' "$PANE_LOG" "the chain break was not loud"
  assert_no_grep 'canned-reply:turn one' "$PANE_LOG" "a broken mailbox still relayed entries (must refuse the WHOLE mailbox)"
  assert_no_grep 'canned-reply:turn two' "$PANE_LOG" "a broken mailbox relayed a message"
  [ "$(grep_lc $'^message-put\x1f')" = 0 ] || fail "inbound relay ran after a chain break (must freeze both directions)"
  # Files retained, nothing deleted.
  [ -n "$(ls "$STATE_DIR/$ID.cloud-mailbox" | grep '^00000001-')" ] || fail "mailbox files were not retained after the break"
  # The marker is sticky: a fresh monitor refuses again without new evidence.
  : > "$PANE_LOG"
  start_monitor
  sleep 2
  stop_monitor
  assert_grep 'CHAIN BREAK recorded' "$PANE_LOG" "the chain-break marker is not sticky across monitor restarts"
  pass "a dropped middle blob refuses the whole mailbox, retains files, freezes relay both ways, and is sticky"
}

test_tampered_content_refuses_whole_mailbox() {
  make_world tampered
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"authentic"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "guest leg did not exit cleanly"
  python3 - "$STORE/session/out" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
first = sorted(out.glob("00000001-*.json"))[0]
message = json.loads(first.read_text())
message["text"] = "forged reply"
first.write_text(json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
  start_monitor
  wait_for "chain-break marker" test -f "$STATE_DIR/$ID.cloud-mailbox/.chain-break"
  stop_monitor
  assert_grep 'SECONDMATE MAILBOX REFUSED' "$PANE_LOG" "tampered content was not refused loudly"
  assert_no_grep 'forged reply' "$PANE_LOG" "tampered content was delivered"
  assert_no_grep 'canned-reply:authentic' "$PANE_LOG" "a tampered mailbox still delivered other entries"
  pass "tampered message content refuses the whole mailbox"
}

test_bundle_lands_by_fast_forward_when_clean() {
  make_world bundle-land
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"do a commit"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  FM_FAKE_PI_MODE=commit run_guest_leg >/dev/null 2>&1 || fail "guest commit leg did not exit cleanly"
  local guest_head
  guest_head=$(git -C "$GUEST_REPO" rev-parse HEAD)
  [ "$guest_head" != "$BASE" ] || fail "fixture guest never committed"
  start_monitor
  wait_for "terminal status" test -f "$STATE_DIR/$ID.cloud-secondmate-status"
  wait_for "bundle landed" grep -q 'landed bundle' "$PANE_LOG"
  stop_monitor
  [ "$(git -C "$LANDING" rev-parse HEAD)" = "$guest_head" ] \
    || fail "clean home worktree did not fast-forward to the compartment's commit"
  pass "a verified declared bundle fast-forwards a clean home worktree to the compartment tip"
}

test_bundle_kept_when_worktree_dirty() {
  make_world bundle-kept
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"do a commit"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  FM_FAKE_PI_MODE=commit run_guest_leg >/dev/null 2>&1 || fail "guest commit leg did not exit cleanly"
  printf 'local edit\n' >> "$LANDING/README.md"
  start_monitor
  wait_for "kept-for-manual-landing report" grep -q 'kept at .* for manual landing' "$PANE_LOG"
  stop_monitor
  [ "$(git -C "$LANDING" rev-parse HEAD)" = "$BASE" ] || fail "a dirty worktree was mutated by bundle landing"
  [ -n "$(ls "$STATE_DIR/$ID.cloud-mailbox" | grep '^bundle-')" ] || fail "the kept bundle is not retained in the mailbox"
  pass "a dirty home worktree keeps the bundle and reports its path instead of landing"
}

test_ttl_refuses_renewal() {
  make_world ttl-refusal
  run_guest_leg FM_SECONDMATE_LEG_SECONDS=2 >/dev/null 2>&1 \
    || fail "guest wall leg did not exit cleanly"
  printf 'export FM_SECONDMATE_TTL_HOURS=0\n' >> "$STATE_DIR/$ID.cloud-env"
  start_monitor
  wait_for "ttl terminal status" test -f "$STATE_DIR/$ID.cloud-secondmate-status"
  stop_monitor
  assert_contains "$(cat "$STATE_DIR/$ID.cloud-secondmate-status")" "ttl-exhausted" "TTL refusal did not record its terminal status"
  assert_grep 'refusing to renew' "$PANE_LOG" "TTL refusal was not loud"
  [ "$(grep_lc $'^execute\x1f')" = 1 ] || fail "TTL-exhausted chain still dispatched a renewal leg"
  pass "renewal past the TTL is refused with a terminal status, never dispatched"
}

test_leg_seconds_above_ceiling_refused_at_startup() {
  make_world leg-ceiling
  # Rewrite (not append): persisted_env_value reads the FIRST match.
  {
    printf 'export FM_AZURE_SUBSCRIPTION_ID=%s\n' "$SUB"
    printf 'export FM_AZURE_STORAGE_NAME=stfixture\n'
    printf 'export FM_SECONDMATE_LEG_SECONDS=19801\n'
  } > "$STATE_DIR/$ID.cloud-env"
  local out status
  out=$(env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SECONDMATE_LIFECYCLE_BIN="$LIFECYCLE_FIXTURE" \
    FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" FM_FIXTURE_STORE="$STORE" \
    "$MONITOR" "$ID" "$GEN" 2>&1)
  status=$?
  expect_code 1 "$status" "an over-ceiling leg budget must refuse at startup: $out"
  assert_contains "$out" "cannot fit its finish-leg budget" "the wall-arithmetic refusal did not explain itself: $out"
  [ ! -s "$LC_LOG" ] || fail "an over-ceiling monitor still dispatched something"
  pass "leg_seconds above 19800 refuses at startup (wall = leg + 1800 must fit 21600)"
}

# --- fm-send compartment routing ----------------------------------------------

# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

make_send_stubs() {  # <dir> -> echoes fakebin (fake tmux logging literal sends)
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  has-session|display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

run_send() {  # <fakebin> <home> <send-log> <fm-send args...>
  local fb=$1 home=$2 log=$3
  shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>&1
}

make_send_home() {  # <name> <with-placement> <with-assignment> -> SEND_HOME/SEND_FB/SEND_LOG
  local name=$1 with_placement=$2 with_assignment=$3 dir
  dir="$TMP_ROOT/send-$name"
  SEND_HOME="$dir/home"
  mkdir -p "$SEND_HOME/state" "$dir/stubs"
  SEND_FB=$(make_send_stubs "$dir/stubs")
  SEND_LOG="$dir/send.log"
  fm_write_secondmate_meta "$SEND_HOME/state/domain.meta" "$SEND_HOME" "firstmate:fm-domain"
  {
    printf 'generation_id=%s\n' "$GEN"
    [ "$with_placement" != 1 ] || printf 'placement=azure\n'
    [ "$with_assignment" != 1 ] || printf 'worker_assignment_generation=%s\n' "$ASSIGNMENT"
  } >> "$SEND_HOME/state/domain.meta"
}

test_fm_send_routes_cloud_secondmate_into_the_compartment_inbox() {
  local out rc inbox
  make_send_home routed 1 1
  inbox="$SEND_HOME/state/domain.cloud-inbox"
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain 'audit the build')
  rc=$?
  expect_code 0 "$rc" "cloud secondmate send should succeed: $out"
  assert_contains "$out" "queued for cloud secondmate" "the routed send did not report its envelope: $out"
  [ ! -s "$SEND_LOG" ] || fail "a cloud secondmate send typed into a local pane: $(cat "$SEND_LOG")"
  python3 - "$inbox" "$ASSIGNMENT" "$FM_FROMFIRST_MARK" <<'PY' || fail "the compartment envelope is not the canonical fenced shape"
import hashlib, json, pathlib, re, sys
inbox, assignment, marker = sys.argv[1:]
files = sorted(p for p in pathlib.Path(inbox).iterdir() if re.fullmatch(r"[0-9]{8}-[0-9a-f]{64}\.json", p.name))
assert len(files) == 1, files
body = files[0].read_bytes()
digest = hashlib.sha256(body).hexdigest()
assert files[0].name == "00000001-{}.json".format(digest), files[0].name
message = json.loads(body)
assert set(message) == {"kind", "text", "nonce"}, message
assert message["kind"] == "fm.secondmate-message/v1"
assert message["nonce"] == assignment + "/00000001", message["nonce"]
assert message["text"] == marker + "audit the build", repr(message["text"])
canonical = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
assert canonical == body, "envelope bytes are not canonical"
PY
  # A second identical send is a NEW message (distinct sequence and nonce),
  # never a silent dedupe of a repeated captain instruction.
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain 'audit the build')
  expect_code 0 $? "second cloud secondmate send should succeed: $out"
  [ "$(ls "$inbox" | grep -c '^00000002-')" = 1 ] || fail "a repeated send did not claim the next sequence"
  # --key has no composer to press.
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain --key Enter)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--key to a cloud compartment must refuse: $out"
  assert_contains "$out" "no local composer" "--key refusal did not explain the compartment lane: $out"
  pass "fm-send routes cloud secondmate text into fenced canonical inbox envelopes; --key refuses"
}

test_fm_send_local_secondmate_path_is_unchanged() {
  local out rc got
  make_send_home local-path 0 0
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain 'route this work')
  rc=$?
  expect_code 0 "$rc" "local secondmate send should succeed: $out"
  got=$(cat "$SEND_LOG")
  [ "$got" = "${FM_FROMFIRST_MARK}route this work" ] \
    || fail "a placement-less secondmate send changed behavior (must stay the marked backend send): $(printf '%s' "$got" | od -An -c | head -3)"
  assert_absent "$SEND_HOME/state/domain.cloud-inbox" "a local secondmate send created a compartment inbox"
  pass "fm-send to a local secondmate stays byte-identical (marker + backend send, no inbox)"
}

test_fm_send_cloud_secondmate_without_assignment_refuses() {
  local out rc
  make_send_home unassigned 1 0
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain 'too early')
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unassigned compartment send must refuse (no generation to fence): $out"
  assert_contains "$out" "no worker assignment yet" "the unassigned refusal did not explain itself: $out"
  [ ! -e "$SEND_HOME/state/domain.cloud-inbox" ] \
    || [ -z "$(ls "$SEND_HOME/state/domain.cloud-inbox" 2>/dev/null | grep -v '^\.')" ] \
    || fail "an unfenced envelope was written despite the refusal"
  pass "fm-send refuses a cloud secondmate send that cannot be generation-fenced"
}

test_leg1_carries_staging_and_leg2_is_manifest_free_golden
test_o_excl_guard_prevents_double_dispatch
test_inbox_relay_is_content_addressed_and_replay_safe
test_verified_chain_delivers_and_close_is_terminal
test_dropped_blob_refuses_whole_mailbox_and_freezes_relay
test_tampered_content_refuses_whole_mailbox
test_bundle_lands_by_fast_forward_when_clean
test_bundle_kept_when_worktree_dirty
test_ttl_refuses_renewal
test_leg_seconds_above_ceiling_refused_at_startup
test_fm_send_routes_cloud_secondmate_into_the_compartment_inbox
test_fm_send_local_secondmate_path_is_unchanged
test_fm_send_cloud_secondmate_without_assignment_refuses

echo "# fm-secondmate-cloud-monitor.test.sh: all assertions passed"
