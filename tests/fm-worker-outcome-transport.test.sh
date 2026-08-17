#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROVIDER="$ROOT/bin/fm-azure-worker-provider.py"

# The controller half of landing v1 (SAS minting, blob download, byte and
# digest verification) is driven here through a FAKE az BINARY rather than a
# stubbed Python seam: the real argv is built, really executed, and its real
# JSON output really parsed, so a rename, a wrong permission set, or a dropped
# verification fails here instead of live.
write_fake_az() {
  cat >"$1" <<'SH'
#!/usr/bin/env bash
# Records every invocation and answers the exact storage calls under test.
printf '%s\n' "$*" >> "$FAKE_AZ_LOG"
mode=""
container=""
name=""
file=""
permissions=""
while [ $# -gt 0 ]; do
  case "$1" in
    storage|blob) shift ;;
    show|download|generate-sas|list|upload|delete) mode=$1; shift ;;
    --container-name) container=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --file) file=$2; shift 2 ;;
    --permissions) permissions=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$mode" in
  show)
    # az --output json renders a scalar --query result as a bare number.
    wc -c < "$FAKE_AZ_BLOB" | tr -d ' '
    ;;
  download)
    cp "$FAKE_AZ_BLOB" "$file"
    printf '{}\n'
    ;;
  generate-sas)
    printf '"https://fixture.invalid/%s/%s?sig=fake&sp=%s"\n' "$container" "$name" "$permissions"
    ;;
  *)
    printf '{}\n'
    ;;
esac
SH
  chmod +x "$1"
}

run_outcome_transport() {
  local tmp bin fixture out status
  fm_test_tmproot_into tmp fm-worker-outcome-transport
  bin="$tmp/bin"
  mkdir -p "$bin" "$tmp/outcome"
  write_fake_az "$bin/az"
  fixture="$tmp/fixture.bundle"
  printf 'pretend git bundle bytes\n' > "$fixture"
  cat >"$tmp/driver.py" <<'PY'
import hashlib
import importlib.util
import sys
from pathlib import Path

provider_path, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_provider", provider_path)
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)

root = Path(tmp)
body = (root / "fixture.bundle").read_bytes()
digest = hashlib.sha256(body).hexdigest()
controller = {
    "subscription": "00000000-0000-0000-0000-000000000000",
    "resource_group": "rg-test", "prefix": "fmtest", "owner": "owner",
    "deployment_generation": "dep-one", "home_binding": "a" * 64,
}
request_digest = "b" * 64

# The blob name is bound to the request digest, so a later execute against the
# same worker cannot overwrite an uncollected outcome.
name = provider.outcome_blob_name(request_digest)
assert name == "outcome-" + "b" * 32 + ".bundle", name
try:
    provider.outcome_blob_name("not-a-digest")
    raise AssertionError("a malformed request digest must not name a blob")
except provider.ProviderError:
    pass

# The outcome SAS is create/write on exactly that one name.
uri = provider.blob_sas(controller, "fmteststorage", "state-c", name, 60, permissions="cw")
assert uri.startswith("https://") and "sp=cw" in uri and name in uri, uri
try:
    provider.blob_sas(controller, "fmteststorage", "state-c", name, 60, permissions="racwd")
    raise AssertionError("an unreviewed permission set must be refused")
except provider.ProviderError:
    pass

target = root / "outcome" / "outcome.bundle"
# Happy path: the bytes land only because size and digest match the claim.
landed = provider.download_outcome_bundle(
    controller, "fmteststorage", "state-c", name, digest, len(body), target,
)
assert landed == len(body), landed
assert target.read_bytes() == body, "the downloaded bundle is not the blob"

# A size claim that disagrees with the blob is refused BEFORE the download.
target.unlink()
try:
    provider.download_outcome_bundle(
        controller, "fmteststorage", "state-c", name, digest, len(body) + 1, target,
    )
    raise AssertionError("a size claim that differs from the blob must be refused")
except provider.ProviderError as exc:
    assert "differs from the digest-bound result claim" in str(exc), exc
assert not target.exists(), "a refused download must not leave a file"

# A digest claim that disagrees with the bytes is refused after the fetch.
try:
    provider.download_outcome_bundle(
        controller, "fmteststorage", "state-c", name, "c" * 64, len(body), target,
    )
    raise AssertionError("a digest claim that differs from the bytes must be refused")
except provider.ProviderError as exc:
    assert "differs from the digest-bound result" in str(exc), exc
assert not target.exists(), "a refused download must not leave a file"
print("OK")
PY
  out=$(PATH="$bin:$PATH" FAKE_AZ_LOG="$tmp/az.log" FAKE_AZ_BLOB="$fixture" \
    FM_AZURE_STORAGE_NAME=fmteststorage \
    python3 "$tmp/driver.py" "$PROVIDER" "$tmp" 2>&1)
  status=$?
  expect_code 0 "$status" "the outcome transport should drive the real provider: $out"
  assert_contains "$out" "OK" "the transport driver did not complete: $out"
  # The size check must really precede the download: prove it from the
  # recorded az calls, not from reading the source.
  assert_grep 'storage blob show' "$tmp/az.log" "the controller never asked the blob its size"
  python3 - "$tmp/az.log" <<'PY' || fail "the size proof does not precede the download"
import sys

lines = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
show = next(i for i, line in enumerate(lines) if "blob show" in line)
download = next(i for i, line in enumerate(lines) if "blob download" in line)
assert show < download, lines
# Three attempts asked the blob its size; only the two whose claim matched went
# on to transfer it. The size-mismatch attempt stopped without a download,
# which is the whole point of asking first.
shows = [i for i, line in enumerate(lines) if "blob show" in line]
downloads = [i for i, line in enumerate(lines) if "blob download" in line]
assert len(shows) == 3 and len(downloads) == 2, lines
followed = [i for i in shows if any(i < d < (i + 2) for d in downloads)]
assert len(followed) == 2, ("a refused size claim still transferred the blob", lines)
PY
  assert_grep 'permissions cw' "$tmp/az.log" "the outcome SAS was not create/write scoped"
  assert_no_grep 'permissions racwd' "$tmp/az.log" "an unreviewed permission set reached the CLI"
  pass "the controller mints a scoped outcome SAS and lands only verified bytes"
}

run_outcome_transport

echo "# fm-worker-outcome-transport.test.sh: all assertions passed"
