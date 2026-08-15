#!/usr/bin/env bash
# Golden-image bake path for Firstmate Azure cells and runners.
#
# Bakes the fixed tool closure (apt packages, uv, shellcheck), the pi-codex
# host CLI (the primary runtime for crewmates, secondmates, and no-mistakes
# cells), the Claude Code CLI (wired only into the cross-check lane), an
# optional runtime bundle, and the agent bootstrap marker into one managed
# image via Azure Image Builder. Deployment code
# prefers the baked image whenever FM_AZURE_BAKED_IMAGE_ID names its resource
# id; otherwise cells and runners keep bootstrapping the stock Ubuntu
# marketplace image.
#
# plan is read-only (validate + what-if). build is billable and requires the
# exact --confirm-build/--confirm-subscription pair plus a clean checkout
# whose HEAD is reachable from freshly fetched public main.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
TEMPLATE="$ROOT/docs/azure-validation/cell-image.json"

usage() {
  cat <<'EOF'
usage:
  fm-azure-cell-image.sh plan  --subscription <id> --resource-group <name> --parameters <file>
  fm-azure-cell-image.sh build --subscription <id> --resource-group <name> --parameters <file> --confirm-build --confirm-subscription <id>

plan validates and what-ifs only. build additionally requires the exact
confirmation flag pair and a clean landed checkout, then runs the image
builder. Export the resulting managed image id as FM_AZURE_BAKED_IMAGE_ID to
make cell and runner deployments prefer it.
EOF
}

fail() { printf 'CELL IMAGE REFUSED: %s\n' "$1" >&2; exit 2; }

require_landed_clean() {
  [ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ] \
    || fail "mutation requires a clean checkout"
  git -C "$ROOT" fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main' \
    || fail "mutation requires fresh public main"
  git -C "$ROOT" merge-base --is-ancestor HEAD refs/remotes/origin/main \
    || fail "mutation requires a HEAD already landed on public main"
}

command=${1:-}
[ -n "$command" ] || { usage; exit 2; }
shift

subscription="" resource_group="" parameters="" confirm_build=0 confirm_subscription=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subscription) subscription=${2:?}; shift 2 ;;
    --resource-group) resource_group=${2:?}; shift 2 ;;
    --parameters) parameters=${2:?}; shift 2 ;;
    --confirm-build) confirm_build=1; shift ;;
    --confirm-subscription) confirm_subscription=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$subscription" ] && [ -n "$resource_group" ] && [ -n "$parameters" ] \
  || fail "--subscription, --resource-group, and --parameters are required"
[ -f "$parameters" ] || fail "parameters file is absent"
python3 -m json.tool "$TEMPLATE" >/dev/null || fail "tracked template is not valid JSON"
if grep -Eq '"ubuntuExactVersion"[[:space:]]*:[[:space:]]*\{[^}]*"latest"' "$parameters" \
  || grep -Eq '"value"[[:space:]]*:[[:space:]]*"latest"' "$parameters"; then
  fail "an exact marketplace image version is required; latest is refused"
fi

deployment=fm-azure-cell-image
case "$command" in
  plan)
    az deployment group validate --subscription "$subscription" \
      --resource-group "$resource_group" --template-file "$TEMPLATE" \
      --parameters "@$parameters" >/dev/null || fail "template validation failed"
    az deployment group what-if --subscription "$subscription" \
      --resource-group "$resource_group" --template-file "$TEMPLATE" \
      --parameters "@$parameters" --no-pretty-print
    ;;
  build)
    [ "$confirm_build" = 1 ] || fail "build requires --confirm-build"
    [ "$confirm_subscription" = "$subscription" ] || fail "--confirm-subscription must exactly match --subscription"
    require_landed_clean
    az deployment group create --subscription "$subscription" \
      --resource-group "$resource_group" --name "$deployment" \
      --template-file "$TEMPLATE" --parameters "@$parameters" >/dev/null \
      || fail "image template deployment failed"
    template_name=$(az deployment group show --subscription "$subscription" \
      --resource-group "$resource_group" --name "$deployment" \
      --query properties.outputs.imageTemplateName.value --output tsv)
    image_id=$(az deployment group show --subscription "$subscription" \
      --resource-group "$resource_group" --name "$deployment" \
      --query properties.outputs.managedImageId.value --output tsv)
    az image builder run --subscription "$subscription" \
      --resource-group "$resource_group" --name "$template_name" \
      || fail "image build run failed"
    printf 'cell image build complete: %s\n' "$template_name"
    printf 'export FM_AZURE_BAKED_IMAGE_ID=%s\n' "$image_id"
    ;;
  *)
    usage
    exit 2
    ;;
esac
