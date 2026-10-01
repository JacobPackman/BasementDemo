#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time bootstrap: provision Azure infra + configure GitHub OIDC.
#
# Run this ONCE from a workstation with Azure CLI logged in as someone who can
# create Entra app registrations and assign RBAC on the subscription.
#   az login
#   az account set --subscription "<sub id>"
#   ./infra/setup-oidc.sh
#
# It prints the three values to paste into GitHub as repository *variables*
# (not secrets -- none of these are sensitive; the trust is the federated
# credential, and no long-lived credential is ever minted).
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- EDIT THESE ------------------------------------------------------------
GITHUB_ORG="CHANGEME"          # GitHub org or username
GITHUB_REPO="CHANGEME"         # repo name, without the org
LOCATION="westus3"
PREFIX="wbs"
RESOURCE_GROUP="rg-wetbasement-prod"
APP_NAME="wbs-github-oidc"     # Entra app registration display name
# ---------------------------------------------------------------------------

echo "==> Creating resource group ${RESOURCE_GROUP} in ${LOCATION}"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none

echo "==> Deploying infrastructure (ACR, ACA env, Container App, storage)"
read -rsp "CMS admin password for /admin: " ADMIN_PASS; echo
read -rsp "Secret key for session signing (random string): " SECRET_KEY; echo

az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file "$(dirname "$0")/main.bicep" \
  --parameters \
      location="${LOCATION}" \
      prefix="${PREFIX}" \
      minReplicas=0 \
      adminPass="${ADMIN_PASS}" \
      secretKey="${SECRET_KEY}" \
  --output none

ACR_NAME=$(az deployment group show -g "${RESOURCE_GROUP}" -n main \
  --query properties.outputs.acrLoginServer.value -o tsv | cut -d. -f1)
echo "    ACR: ${ACR_NAME}"

# Managed-identity image pull from ACR requires ACR to trust ARM tokens.
echo "==> Enabling ARM-token auth on ACR (required for managed identity pull)"
az acr config authentication-as-arm update --registry "${ACR_NAME}" --status enabled --output none

# ---------------------------------------------------------------------------
# Entra ID app registration + federated credentials (the OIDC trust)
# ---------------------------------------------------------------------------
echo "==> Creating Entra app registration ${APP_NAME}"
APP_ID=$(az ad app create --display-name "${APP_NAME}" --query appId -o tsv)

az ad sp create --id "${APP_ID}" --output none
echo "    client id: ${APP_ID}"

# Two federated credentials: one per GitHub Environment. Scoping to an
# environment means a compromised workflow on the default branch still cannot
# authenticate for a prod deploy.
echo "==> Adding federated credentials (dev + prod environments)"
for ENV_NAME in dev prod; do
  az ad app federated-credential create \
    --id "${APP_ID}" \
    --parameters "{
      \"name\": \"github-${ENV_NAME}\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:${ENV_NAME}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" --output none
  echo "    subject: repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:${ENV_NAME}"
done

# Also allow push-triggered builds (no environment) to authenticate, since the
# build job runs before any environment is selected.
az ad app federated-credential create \
  --id "${APP_ID}" \
  --parameters "{
    \"name\": \"github-branch-main\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none

# ---------------------------------------------------------------------------
# RBAC -- least privilege, scoped to the resource group
# ---------------------------------------------------------------------------
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SP_OBJECT_ID=$(az ad sp show --id "${APP_ID}" --query id -o tsv)

echo "==> Granting RBAC on ${RESOURCE_GROUP}"
az role assignment create \
  --assignee-object-id "${SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}" \
  --output none

# TIGHTER (recommended once the pipeline is stable -- drop the Contributor
# grant above and use these two instead):
#   --role AcrPush                 --scope <acr resource id>
#   --role "Container Apps Contributor" --scope <container app resource id>

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo
echo "=========================================================="
echo " Set these as GitHub *Actions variables* on ${GITHUB_ORG}/${GITHUB_REPO}:"
echo "   AZURE_CLIENT_ID       = ${APP_ID}"
echo "   AZURE_TENANT_ID       = $(az account show --query tenantId -o tsv)"
echo "   AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo "=========================================================="
echo
echo " Then create two GitHub Environments: 'dev' (no gate) and"
echo " 'prod' (deselect 'Allow administrators to bypass', add required reviewers)."
echo
echo " Check the app URL:"
az deployment group show -g "${RESOURCE_GROUP}" -n main \
  --query properties.outputs.containerAppFqdn.value -o tsv
