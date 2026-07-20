#!/usr/bin/env bash
# Deploys a small Ubuntu VM that runs a self-hosted Azure DevOps agent.
#
# Required environment:
#   AZP_URL    - Azure DevOps org URL, e.g. https://dev.azure.com/myorg
#   AZP_TOKEN  - PAT with scope "Agent Pools (Read & manage)" (prompted if unset)
# Optional overrides:
#   RG, LOCATION, VM_NAME, VM_SIZE, ADMIN_USER, AZP_POOL
#
# Usage:  AZP_URL=https://dev.azure.com/myorg ./deploy-agent-vm.sh
set -euo pipefail
cd "$(dirname "$0")"

RG="${RG:-rg-ado-agent}"
LOCATION="${LOCATION:-westeurope}"
VM_NAME="${VM_NAME:-vm-ado-agent}"
# B2s (2 vCPU / 4 GiB) is comfortable; Standard_B1ms (1 vCPU / 2 GiB) also
# works and halves the cost - the agent only orchestrates Packer, the heavy
# lifting happens on the temporary build VM that Packer creates itself.
VM_SIZE="${VM_SIZE:-Standard_B2s}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
AZP_POOL="${AZP_POOL:-Default}"

: "${AZP_URL:?Set AZP_URL to your Azure DevOps org URL, e.g. https://dev.azure.com/myorg}"
if [[ -z "${AZP_TOKEN:-}" ]]; then
  read -r -s -p "Azure DevOps PAT (Agent Pools - Read & manage): " AZP_TOKEN; echo
fi

echo "==> Rendering cloud-init"
CLOUD_INIT="$(mktemp)"
trap 'rm -f "$CLOUD_INIT"' EXIT
sed -e "s|__AZP_URL__|${AZP_URL}|" \
    -e "s|__AZP_POOL__|${AZP_POOL}|" \
    -e "s|__AZP_TOKEN__|${AZP_TOKEN}|" \
    cloud-init.tpl.yaml > "$CLOUD_INIT"

echo "==> Resource group ${RG} (${LOCATION})"
az group create --name "$RG" --location "$LOCATION" --output none

echo "==> Network (SSH allowed only from your current public IP)"
MY_IP="$(curl -fsS https://api.ipify.org)"
az network nsg create --resource-group "$RG" --name "${VM_NAME}-nsg" --output none
az network nsg rule create --resource-group "$RG" --nsg-name "${VM_NAME}-nsg" \
  --name allow-ssh-admin --priority 100 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 22 \
  --source-address-prefixes "${MY_IP}/32" --output none
az network vnet create --resource-group "$RG" --name "${VM_NAME}-vnet" \
  --address-prefix 10.60.0.0/24 \
  --subnet-name agents --subnet-prefix 10.60.0.0/27 \
  --network-security-group "${VM_NAME}-nsg" --output none

echo "==> VM ${VM_NAME} (${VM_SIZE})"
az vm create \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --image Canonical:ubuntu-24_04-lts:server:latest \
  --size "$VM_SIZE" \
  --vnet-name "${VM_NAME}-vnet" --subnet agents \
  --nsg "" \
  --public-ip-sku Standard \
  --storage-sku StandardSSD_LRS \
  --os-disk-size-gb 64 \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --assign-identity \
  --custom-data "$CLOUD_INIT" \
  --output table

echo "==> Waiting for cloud-init to finish (agent install takes a few minutes)"
az vm run-command invoke --resource-group "$RG" --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "cloud-init status --wait || true; systemctl --no-pager --type=service list-units 'vsts.agent.*' ; tail -n 20 /var/log/ado-agent-bootstrap.log" \
  --query 'value[0].message' -o tsv

echo
echo "Done. Verify the agent is Online under:"
echo "  ${AZP_URL}/_settings/agentpools (pool: ${AZP_POOL})"
