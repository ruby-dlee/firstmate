#!/usr/bin/env bash
# Golden-image bake for Azure cell and runner VMs.
#
# Boots one builder VM from the same Canonical Ubuntu 24.04 base the
# templates use, installs the union of the cell and runner bootstrap
# package sets, stages the pinned tool closure (ShellCheck, uv) plus the
# interpreter closure (nodesource node 22, deadsnakes python3.11) under
# /opt/fm-tools with recorded digests, then generalizes and captures a
# managed image in the resource group. Guests re-verify every staged
# archive digest at boot before trusting it, so the image is a cache of
# the provenance chain, never a replacement for it.
#
# usage:
#   fm-azure-cell-image.sh bake --confirm-bake --confirm-subscription <id>
#
# Prints the managed image resource id on success. Point
# FM_AZURE_VM_IMAGE_ID at it to make cells and runners boot from it.
set -euo pipefail

SHELLCHECK_URL=https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz
SHELLCHECK_BYTES=2559196
SHELLCHECK_DIGEST=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
UV_URL=https://github.com/astral-sh/uv/releases/download/0.9.10/uv-x86_64-unknown-linux-gnu.tar.gz
UV_BYTES=21427164
UV_DIGEST=440c4215b171e64061d65d16a23753dd25c29a7f7b1b0446c9e9aed0fa372f27

command=${1:-}
shift || true
confirm_bake=0
confirm_subscription=""
while [ $# -gt 0 ]; do
  case "$1" in
    --confirm-bake) confirm_bake=1; shift ;;
    --confirm-subscription) confirm_subscription=${2:?}; shift 2 ;;
    *) echo "fm-azure-cell-image: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ "$command" = bake ] || { echo "usage: fm-azure-cell-image.sh bake --confirm-bake --confirm-subscription <id>" >&2; exit 2; }
SUBSCRIPTION=${FM_AZURE_SUBSCRIPTION_ID:?FM_AZURE_SUBSCRIPTION_ID is required}
RESOURCE_GROUP=${FM_AZURE_RESOURCE_GROUP:?FM_AZURE_RESOURCE_GROUP is required}
[ "$confirm_bake" = 1 ] && [ "$confirm_subscription" = "$SUBSCRIPTION" ] \
  || { echo "fm-azure-cell-image: bake requires --confirm-bake and the exact subscription" >&2; exit 2; }

STAMP=$(date -u +%Y%m%d%H%M%S)
BUILDER=vm-fmimg-builder-$STAMP
IMAGE=img-fm-cell-$STAMP
az() { command az "$@" --subscription "$SUBSCRIPTION" --only-show-errors; }

echo "fm-azure-cell-image: creating builder $BUILDER" >&2
KEYDIR=$(mktemp -d)
trap 'rm -rf "$KEYDIR"' EXIT
ssh-keygen -t ed25519 -N "" -q -f "$KEYDIR/throwaway"
az vm create --resource-group "$RESOURCE_GROUP" --name "$BUILDER" \
  --image Canonical:ubuntu-24_04-lts:server:latest --size Standard_D4as_v6 \
  --os-disk-size-gb 96 --storage-sku StandardSSD_LRS \
  --admin-username fmbake --ssh-key-values "$KEYDIR/throwaway.pub" \
  --public-ip-address "" --nsg "" --output none

BAKE=$(mktemp)
trap 'rm -f "$BAKE"; rm -rf "$KEYDIR"' EXIT
cat >"$BAKE" <<EOF
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl git python3 python3-venv e2fsprogs util-linux passwd \
  systemd tmux jq xz-utils ripgrep cryptsetup-bin tar software-properties-common gnupg
# Interpreter closure: node 22 (module-detecting) and python 3.11.
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
add-apt-repository -y ppa:deadsnakes/ppa
apt-get install -y python3.11 python3.11-venv
# Staged pinned tool closure with recorded digests for boot re-verification.
install -d -m 0755 /opt/fm-tools
curl -fsSL --max-filesize $SHELLCHECK_BYTES -o /opt/fm-tools/shellcheck.tar.xz "$SHELLCHECK_URL"
echo "$SHELLCHECK_DIGEST  /opt/fm-tools/shellcheck.tar.xz" | sha256sum -c -
curl -fsSL --max-filesize $UV_BYTES -o /opt/fm-tools/uv.tar.gz "$UV_URL"
echo "$UV_DIGEST  /opt/fm-tools/uv.tar.gz" | sha256sum -c -
apt-get clean
waagent -deprovision+user -force
EOF
echo "fm-azure-cell-image: baking (packages + closure)" >&2
az vm run-command invoke --resource-group "$RESOURCE_GROUP" --name "$BUILDER" \
  --command-id RunShellScript --scripts @"$BAKE" --output none

echo "fm-azure-cell-image: capturing image $IMAGE" >&2
az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$BUILDER" --output none
az vm generalize --resource-group "$RESOURCE_GROUP" --name "$BUILDER" --output none
az image create --resource-group "$RESOURCE_GROUP" --name "$IMAGE" \
  --source "$BUILDER" --hyper-v-generation V2 --output none
IMAGE_ID=$(az image show --resource-group "$RESOURCE_GROUP" --name "$IMAGE" --query id -o tsv)

echo "fm-azure-cell-image: deleting builder" >&2
az vm delete --resource-group "$RESOURCE_GROUP" --name "$BUILDER" --yes --output none
for kind in disk nic; do
  for id in $(az resource list --resource-group "$RESOURCE_GROUP" \
    --query "[?contains(name, '$BUILDER')].id" -o tsv); do
    az resource delete --ids "$id" --output none || true
  done
done

printf 'FM_AZURE_CELL_IMAGE %s\n' "$IMAGE_ID"
