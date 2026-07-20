#!/usr/bin/env bash
# Pushes this repository to Azure Repos and creates the image-build pipeline
# from azure-pipelines.yml.
#
# Required environment:
#   ORG_URL  - e.g. https://dev.azure.com/myorg
#   PROJECT  - Azure DevOps project name
# Optional:
#   REPO_NAME     (default: Packer)
#   PIPELINE_NAME (default: win11-image-build)
#
# Prereqs: az login done; run from anywhere, operates on the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${ORG_URL:?Set ORG_URL, e.g. https://dev.azure.com/myorg}"
: "${PROJECT:?Set PROJECT to your Azure DevOps project name}"
REPO_NAME="${REPO_NAME:-Packer}"
PIPELINE_NAME="${PIPELINE_NAME:-win11-image-build}"

az extension add --name azure-devops --upgrade --only-show-errors
az devops configure --defaults organization="$ORG_URL" project="$PROJECT"

echo "==> Creating Azure Repos repository '${REPO_NAME}' (ignored if it exists)"
az repos create --name "$REPO_NAME" --output none 2>/dev/null || true
# Strip the embedded username from the remote URL - with a username present,
# git falls back to basic/keychain credentials which override the bearer
# token header below and cause a 403.
REMOTE_URL=$(az repos show --repository "$REPO_NAME" --query remoteUrl -o tsv \
  | sed 's#//[^@/]*@#//#')

if [[ ! -d .git ]]; then
  echo "==> Initializing git repository"
  git init -b main
  cat > .gitignore <<'EOF'
win11.auto.pkrvars.hcl
*.pkrvars.hcl
!*.pkrvars.hcl.example
EOF
  git add -A
  git commit -m "Packer win11 image build + ADO agent infra"
fi

git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REMOTE_URL"

echo "==> Pushing to ${REMOTE_URL}"
# Authenticate git with the az login session via an Azure DevOps access token
# (499b84ac-... is the fixed resource ID of the Azure DevOps service).
ADO_TOKEN=$(az account get-access-token \
  --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv)
git -c credential.helper= \
    -c http.extraheader="AUTHORIZATION: bearer ${ADO_TOKEN}" push -u origin main

echo "==> Creating pipeline '${PIPELINE_NAME}'"
az pipelines create \
  --name "$PIPELINE_NAME" \
  --repository "$REPO_NAME" \
  --repository-type tfsgit \
  --branch main \
  --yml-path azure-pipelines.yml \
  --skip-first-run \
  --output table

echo
echo "Done. Edit the variables block in azure-pipelines.yml (subscriptionId,"
echo "gallery names) before the first run, then start it with:"
echo "  az pipelines run --name ${PIPELINE_NAME}"
