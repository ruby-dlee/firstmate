#!/usr/bin/env bash
# Trusted root-side Azure Crosscheck model-compartment payload.
#
# This compartment receives exactly one reviewer credential and no repository.
# Every repository read/grep/diff/evidence command is delegated to a fresh
# identity-less `crosscheck-tool` Azure runner invocation through the fixed
# model-image tool bridge. The accepted evidence is replayed by that bridge in
# another new runner invocation before it publishes a verdict.
set -euo pipefail
umask 077

[ "$#" -eq 7 ] || { echo "model guest: expected seven bound parameters" >&2; exit 125; }
REVIEW_GENERATION=$1
VM_RESOURCE_ID=$2
VM_INSTANCE_ID=$3
GUEST_DIGEST=$4
INPUT_URL=$5
CREDENTIAL_URL=$6
OUTPUT_URL=$7
set --

case "$REVIEW_GENERATION" in [0-9a-f][0-9a-f]*) ;; *) echo "model guest: malformed review generation" >&2; exit 125 ;; esac
case "$GUEST_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "model guest: malformed guest digest" >&2; exit 125 ;; esac
[ -n "$VM_RESOURCE_ID" ] && [ -n "$VM_INSTANCE_ID" ] || { echo "model guest: missing VM identity" >&2; exit 125; }
case "$INPUT_URL" in https://*) ;; *) echo "model guest: input capability is not HTTPS" >&2; exit 125 ;; esac
case "$CREDENTIAL_URL" in https://*) ;; *) echo "model guest: credential capability is not HTTPS" >&2; exit 125 ;; esac
case "$OUTPUT_URL" in https://*) ;; *) echo "model guest: output capability is not HTTPS" >&2; exit 125 ;; esac

BASE=/var/lib/fm-crosscheck-model
rm -rf "$BASE"
install -d -m 0700 -o root -g root "$BASE"
INPUT=$BASE/request.json
CREDENTIAL=$BASE/credential.tar.gz
curl --fail --silent --show-error --output "$INPUT" "$INPUT_URL"
curl --fail --silent --show-error --output "$CREDENTIAL" "$CREDENTIAL_URL"
unset INPUT_URL CREDENTIAL_URL

python3 - "$INPUT" "$REVIEW_GENERATION" "$GUEST_DIGEST" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
generation = sys.argv[2]
guest_digest = sys.argv[3]
if path.stat().st_size > 2 * 1024 * 1024:
    raise SystemExit("model guest: request exceeds byte bound")
value = json.loads(path.read_text(encoding="utf-8"))
if value.get("schema") != "fm.azure-crosscheck/v1":
    raise SystemExit("model guest: request schema mismatch")
unsigned = dict(value)
supplied = unsigned.pop("request_digest", None)
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
if supplied != "sha256:" + hashlib.sha256(canonical).hexdigest():
    raise SystemExit("model guest: request digest mismatch")
if value.get("identity", {}).get("review_generation") != generation:
    raise SystemExit("model guest: review generation mismatch")
if value.get("protocol", {}).get("model_guest_digest") != guest_digest:
    raise SystemExit("model guest: guest digest mismatch")
if value.get("tool_protocol", {}).get("network_bytes") != 0:
    raise SystemExit("model guest: repository tool contract is not networkless")
PY

# The pinned image owns the reviewer CLI closure and a local unprivileged tool
# client. The controller never accepts a mutable bridge endpoint: exactly one
# systemd socket, installed from the reviewed image, speaks the bounded RPC.
# The server owns fresh tool/verifier Azure runners and returns only output and
# compartment identities. The model process can never invoke Azure itself.
BRIDGE_CLIENT=/usr/local/libexec/fm-crosscheck-tool-client
[ -x "$BRIDGE_CLIENT" ] || { echo "model guest: pinned tool client is absent" >&2; exit 125; }
command -v jq >/dev/null 2>&1 || { echo "model guest: jq is absent from pinned image" >&2; exit 125; }

HARNESS=$(jq -r '.reviewer.harness' "$INPUT")
MODEL=$(jq -r '.reviewer.model' "$INPUT")
EFFORT=$(jq -r '.reviewer.effort' "$INPUT")
PROMPT=$BASE/prompt.txt
SCHEMA=$BASE/schema.json
jq -r '.prompt' "$INPUT" >"$PROMPT"
jq -c '.review_schema' "$INPUT" >"$SCHEMA"

ACCOUNT=$BASE/account
HOME_DIR=$BASE/home
install -d -m 0700 -o root -g root "$ACCOUNT" "$HOME_DIR"
python3 - "$CREDENTIAL" "$ACCOUNT" <<'PY'
import pathlib
import sys
import tarfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
with tarfile.open(source, "r:gz") as archive:
    members = archive.getmembers()
    names = {member.name for member in members}
    if "manifest.json" not in names or len(names) != 2:
        raise SystemExit("model guest: credential archive shape mismatch")
    for member in members:
        if not member.isfile() or member.issym() or member.islnk() or member.isdev() or member.size > 64 * 1024:
            raise SystemExit("model guest: unsafe credential archive member")
    archive.extractall(destination, members=members)
PY
rm -f "$CREDENTIAL"

export HOME="$HOME_DIR"
export TMPDIR="$BASE/tmp"
export XDG_CACHE_HOME="$BASE/cache"
install -d -m 0700 -o root -g root "$TMPDIR" "$XDG_CACHE_HOME"
export FM_CROSSCHECK_AZURE_TOOL_BRIDGE="$BRIDGE_CLIENT"
export FM_CROSSCHECK_REVIEW_GENERATION="$REVIEW_GENERATION"
export FM_CROSSCHECK_REQUEST="$INPUT"
export FM_CROSSCHECK_REQUEST_ROOT="$BASE"
unset AZURE_CONFIG_DIR ARM_CLIENT_ID ARM_CLIENT_SECRET AZURE_CLIENT_ID AZURE_CLIENT_SECRET SSH_AUTH_SOCK DOCKER_HOST

RESULT=$BASE/reviewer-result.json
case "$HARNESS" in
  codex)
    export CODEX_HOME="$ACCOUNT"
    codex exec -C "$BASE" --sandbox read-only --ephemeral --strict-config \
      --ignore-user-config --ignore-rules \
      -c project_doc_max_bytes=0 --model "$MODEL" \
      -c "model_reasoning_effort=\"$EFFORT\"" \
      --color never --output-schema "$SCHEMA" --output-last-message "$RESULT" - <"$PROMPT"
    ;;
  claude)
    export CLAUDE_CONFIG_DIR="$ACCOUNT"
    export CLAUDE_SECURESTORAGE_CONFIG_DIR="$ACCOUNT"
    claude -p --safe-mode --model "$MODEL" --effort "$EFFORT" \
      --dangerously-skip-permissions --tools Read --no-session-persistence \
      --output-format json --json-schema "$(<"$SCHEMA")" "$(<"$PROMPT")" >"$BASE/claude-envelope.json"
    jq -e '.is_error == false and .subtype == "success" and .terminal_reason == "completed" and (.structured_output|type == "object")' "$BASE/claude-envelope.json" >/dev/null
    jq -c '.structured_output' "$BASE/claude-envelope.json" >"$RESULT"
    ;;
  pi)
    export PI_CODING_AGENT_DIR="$ACCOUNT"
    pi --mode json --provider openai-codex --model "$MODEL" --thinking "$EFFORT" \
      --tools read --no-session --no-extensions --no-skills --no-prompt-templates \
      --no-themes --no-context-files --no-approve "$(<"$PROMPT")" >"$BASE/pi-events.jsonl"
    python3 - "$BASE/pi-events.jsonl" "$RESULT" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
final = None
ended = False
for line in source.read_text(encoding="utf-8").splitlines():
    event = json.loads(line)
    if event.get("type") == "turn_end":
        message = event.get("message") or {}
        if message.get("role") == "assistant" and message.get("stopReason") == "stop":
            content = message.get("content")
            if isinstance(content, str):
                final = content
            elif isinstance(content, list):
                final = "".join(part.get("text", "") for part in content if isinstance(part, dict))
    elif event.get("type") == "agent_end":
        ended = True
if not ended or not final:
    raise SystemExit("model guest: Pi stopped without a successful verdict")
value = json.loads(final)
destination.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
    ;;
  *)
    echo "model guest: unsupported reviewer harness" >&2
    exit 125
    ;;
esac

[ -s "$RESULT" ] || { echo "model guest: reviewer produced no verdict" >&2; exit 125; }
# The trusted bridge server must independently replay every accepted helper in
# another fresh networkless VM and emit exact tool/verifier identities before
# publication. The unprivileged client only writes one bounded RPC and reads one
# bounded reply; it has no Azure credential or socket other than this endpoint.
BRIDGE_RESULT=$BASE/bridge-result.json
"$BRIDGE_CLIENT" finalize --request "$INPUT" --verdict "$RESULT" --output "$BRIDGE_RESULT"

python3 - "$INPUT" "$RESULT" "$BRIDGE_RESULT" "$BASE/output.json" "$VM_RESOURCE_ID" "$VM_INSTANCE_ID" <<'PY'
import hashlib
import json
import pathlib
import sys

request = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
verdict = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
bridge = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
identity = request["identity"]
for label in ("tool_identity", "verifier_identity"):
    value = bridge.get(label)
    if not isinstance(value, dict):
        raise SystemExit("model guest: bridge omitted " + label)
    if value.get("review_generation") != identity["review_generation"]:
        raise SystemExit("model guest: bridge generation mismatch")
    if value.get("network_bytes") != 0 or value.get("credential_present") is not False:
        raise SystemExit("model guest: bridge did not prove networkless credentialless execution")
evidence_files = bridge.get("evidence_files")
if not isinstance(evidence_files, dict):
    raise SystemExit("model guest: bridge omitted reviewed evidence files")
output = {
    "schema": "fm.azure-crosscheck-result/v1",
    **identity,
    "model_resource_id": sys.argv[5],
    "model_vm_instance_id": sys.argv[6],
    "verdict": verdict,
    "evidence_files": evidence_files,
    "tool_identity": bridge["tool_identity"],
    "verifier_identity": bridge["verifier_identity"],
}
path = pathlib.Path(sys.argv[4])
path.write_text(json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

OUTPUT=$BASE/output.json
DIGEST=sha256:$(sha256sum "$OUTPUT" | awk '{print $1}')
printf 'url = "%s"\nfail\nsilent\nshow-error\nrequest = "PUT"\nheader = "x-ms-blob-type: BlockBlob"\nupload-file = "%s"\n' "$OUTPUT_URL" "$OUTPUT" >"$BASE/curl-output.conf"
unset OUTPUT_URL
curl --config "$BASE/curl-output.conf"
rm -f "$BASE/curl-output.conf"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
printf 'FM_AZURE_CROSSCHECK_RESULT %s boot=%s\n' "$DIGEST" "$BOOT_ID"
