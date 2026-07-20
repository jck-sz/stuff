#!/usr/bin/env bash
# Creates an Azure Resource Manager service connection in Azure DevOps,
# backed by a new service principal with Contributor on the subscription
# (Packer creates a temporary resource group per build, so it needs
# subscription scope).
#
# Required environment:
#   ORG_URL  - e.g. https://dev.azure.com/myorg
#   PROJECT  - Azure DevOps project name
# Optional:
#   SC_NAME  - service connection name   (default: sc-azure-packer)
#   SP_NAME  - service principal name    (default: sp-ado-packer)
#
# Prereqs: az login done; the signed-in identity must be able to create
# app registrations in Entra ID and administer the DevOps project.
set -euo pipefail

: "${ORG_URL:?Set ORG_URL, e.g. https://dev.azure.com/myorg}"
: "${PROJECT:?Set PROJECT to your Azure DevOps project name}"
SC_NAME="${SC_NAME:-sc-azure-packer}"
SP_NAME="${SP_NAME:-sp-ado-packer}"

az extension add --name azure-devops --upgrade --only-show-errors

SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "==> Subscription: ${SUB_NAME} (${SUB_ID})"

echo "==> Creating service principal ${SP_NAME} (Contributor on subscription)"
SP_JSON=$(az ad sp create-for-rbac \
  --name "$SP_NAME" \
  --role Contributor \
  --scopes "/subscriptions/${SUB_ID}" \
  --output json)
APP_ID=$(echo "$SP_JSON" | jq -r '.appId')
SP_SECRET=$(echo "$SP_JSON" | jq -r '.password')

echo "==> Creating service connection '${SC_NAME}' in ${PROJECT}"
export AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY="$SP_SECRET"
EP_ID=$(az devops service-endpoint azurerm create \
  --azure-rm-service-principal-id "$APP_ID" \
  --azure-rm-subscription-id "$SUB_ID" \
  --azure-rm-subscription-name "$SUB_NAME" \
  --azure-rm-tenant-id "$TENANT_ID" \
  --name "$SC_NAME" \
  --organization "$ORG_URL" \
  --project "$PROJECT" \
  --query id -o tsv)

echo "==> Granting access to all pipelines in the project"
az devops service-endpoint update \
  --id "$EP_ID" \
  --enable-for-all true \
  --organization "$ORG_URL" \
  --project "$PROJECT" \
  --output none

echo
echo "Done. Service connection '${SC_NAME}' (id ${EP_ID}) is ready."
echo "Note: the SP secret expires in ~1 year (az default). Rotate with:"
echo "  az ad sp credential reset --id ${APP_ID}"
