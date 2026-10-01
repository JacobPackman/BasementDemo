#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time bootstrap: provision Azure infra + configure GitHub OIDC.
#
# Run ONCE from a workstation with Azure CLI logged in as someone who is Owner
# on the subscription (or can at least create app registrations + assign RBAC).
#
#   az login
#   az account set --subscription "<sub id>"
#   ADMIN_PASS='...' SECRET_KEY='...' GITHUB_ORG=x GITHUB_REPO=y ./infra/setup-oidc.sh
#
# Safe to re-run: it reuses an existing app registration of the same name
# instead of failing.
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- CONFIG ----------------------------------------------------------------
GITHUB_ORG="${GITHUB_ORG:-CHANGEME}"
GITHUB_REPO="${GITHUB_REPO:-CHANGEME}"
LOCATION="${LOCATION:-westus3}"
PREFIX="${PREFIX:-wbs}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-wetbasement-demo}"
APP_NAME="${APP_NAME:-wbs-github-oidc}"
MIN_REPLICAS="${MIN_REPLICAS:-0}"
IMAGE_NAME="${IMAGE_NAME:-wbs-web}"
DEPLOYMENT_NAME="wbs-infra"
# ---------------------------------------------------------------------------

if [[ "$GITHUB_ORG" == "CHANGEME" || "$GITHUB_REPO" == "CHANGEME" ]]; then
  echo "ERROR: set GITHUB_ORG and GITHUB_REPO (env vars or edit this file)." >&2
  exit 1
fi

# Secrets: take from env for non-interactive runs, else prompt.
if [[ -z "${ADMIN_PASS:-}" ]]; then
  read -rsp "CMS admin password for /admin: " ADMIN_PASS; echo
fi
if [[ -z "${SECRET_KEY:-}" ]]; then
  SECRET_KEY="$(head -c 48 /dev/urandom | base64 | tr -d '\n/+=' | head -c 48)"
  echo "==> Generated SECRET_KEY (session signing)"
fi

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "==> Subscription ${SUBSCRIPTION_ID} / tenant ${TENANT_ID}"

echo "==> Creating resource group ${RESOURCE_GROUP} in ${LOCATION}"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none

# ---------------------------------------------------------------------------
# Phase 1 -- registry, environment, storage, identity, RBAC (no app yet)
#
# The Container App cannot be created before an image exists, and the image
# cannot be pushed before the registry exists. So: infra first, then build,
# then the app.
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

deploy() {
  local app_flag="$1"
  az deployment group create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${DEPLOYMENT_NAME}" \
    --template-file "$(dirname "$0")/main.bicep" \
    --parameters \
        location="${LOCATION}" \
        prefix="${PREFIX}" \
        minReplicas="${MIN_REPLICAS}" \
        deployApp="${app_flag}" \
        adminPass="${ADMIN_PASS}" \
        secretKey="${SECRET_KEY}" \
    --query "properties.outputs" -o json > /tmp/wbs_outputs.json
}

echo "==> Phase 1/3: deploying registry, environment and storage"
echo "    this takes several minutes..."
deploy false

jq_get() { jq -r ".$1.value" /tmp/wbs_outputs.json; }
ACR_LOGIN_SERVER="$(jq_get acrLoginServer)"
ACR_NAME="${ACR_LOGIN_SERVER%%.*}"
echo "    ACR: ${ACR_NAME}"

# Managed-identity image pull requires ACR to trust ARM tokens. This MUST run
# before the Container App deploys, or the app cannot pull its own image.
echo "==> Enabling ARM-token auth on ACR (needed for managed-identity pull)"
az acr config authentication-as-arm update \
  --registry "${ACR_NAME}" --status enabled --output none

# ---------------------------------------------------------------------------
# Phase 2 -- build and push the first image, server-side in ACR.
# This also proves the Dockerfile actually builds.
# ---------------------------------------------------------------------------
echo "==> Phase 2/3: building the first image in ACR (az acr build)"
az acr build \
  --registry "${ACR_NAME}" \
  --image "${IMAGE_NAME}:latest" \
  --file "${REPO_ROOT}/Dockerfile" \
  "${REPO_ROOT}" \
  --output none
echo "    pushed ${IMAGE_NAME}:latest"

# ---------------------------------------------------------------------------
# Phase 3 -- now the Container App can come up with a real image
# ---------------------------------------------------------------------------
echo "==> Phase 3/3: deploying the Container App"
deploy true

APP_NAME_AZ="$(jq_get containerAppName)"
APP_FQDN="$(jq_get containerAppFqdn)"
echo "    ContainerApp: ${APP_NAME_AZ}"
echo "    FQDN        : https://${APP_FQDN}"

# ---------------------------------------------------------------------------
# Entra ID app registration + federated credentials (the OIDC trust)
# ---------------------------------------------------------------------------
if APP_ID="$(az ad app list --display-name "${APP_NAME}" --query "[0].appId" -o tsv 2>/dev/null)" \
   && [[ -n "${APP_ID}" ]]; then
  echo "==> Reusing existing app registration ${APP_NAME} (${APP_ID})"
else
  echo "==> Creating Entra app registration ${APP_NAME}"
  APP_ID="$(az ad app create --display-name "${APP_NAME}" --query appId -o tsv)"
fi

# Service principal (idempotent)
if ! az ad sp show --id "${APP_ID}" --output none 2>/dev/null; then
  az ad sp create --id "${APP_ID}" --output none
fi
echo "    client id: ${APP_ID}"

echo "==> Adding federated credentials (dev + prod environments + main branch)"
add_fed() {
  local name="$1" subject="$2"
  az ad app federated-credential create \
    --id "${APP_ID}" \
    --parameters "{
      \"name\": \"${name}\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"${subject}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" --output none 2>/dev/null \
  || echo "    (${name} already exists)"
  echo "    subject: ${subject}"
}

# Scoped to a GitHub Environment, so a compromised default-branch workflow
# cannot authenticate for a prod deploy.
#
# NOTE: GitHub now emits IMMUTABLE subjects containing the numeric owner and
# repo IDs, e.g.
#   repo:OWNER@<owner_id>/REPO@<repo_id>:ref:refs/heads/main
# while older tokens used the name-only form. If only the name-only subject is
# registered, azure/login fails with:
#   AADSTS700213: No matching federated identity record found for presented
#   assertion subject 'repo:OWNER@ID/REPO@ID:ref:refs/heads/main'
# So register BOTH forms for every subject. Harmless, and immune to the rollout.
OWNER_ID="$(gh api "repos/${GITHUB_ORG}/${GITHUB_REPO}" --jq '.owner.id' 2>/dev/null || echo '')"
REPO_ID="$(gh api "repos/${GITHUB_ORG}/${GITHUB_REPO}" --jq '.id' 2>/dev/null || echo '')"

for spec in "dev:environment:dev" "prod:environment:prod" "branch:ref:refs/heads/main"; do
  label="${spec%%:*}"
  suffix="${spec#*:}"
  add_fed "github-${label}" "repo:${GITHUB_ORG}/${GITHUB_REPO}:${suffix}"
  if [[ -n "${OWNER_ID}" && -n "${REPO_ID}" ]]; then
    add_fed "gh-imm-${label}" \
      "repo:${GITHUB_ORG}@${OWNER_ID}/${GITHUB_REPO}@${REPO_ID}:${suffix}"
  fi
done
if [[ -z "${OWNER_ID}" || -z "${REPO_ID}" ]]; then
  echo "    WARNING: could not resolve repo IDs (gh not authed?). If azure/login"
  echo "    fails with AADSTS700213, re-run this script once gh is authenticated."
fi

# ---------------------------------------------------------------------------
# RBAC -- scoped to the resource group
# ---------------------------------------------------------------------------
SP_OBJECT_ID="$(az ad sp show --id "${APP_ID}" --query id -o tsv)"
RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"

echo "==> Granting Contributor on ${RESOURCE_GROUP}"
az role assignment create \
  --assignee-object-id "${SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "${RG_SCOPE}" \
  --output none 2>/dev/null || echo "    (assignment already exists)"

# ---------------------------------------------------------------------------
# Push the values into GitHub (if gh is available and authenticated)
# ---------------------------------------------------------------------------
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "==> Setting GitHub repository variables on ${GITHUB_ORG}/${GITHUB_REPO}"
  gh variable set AZURE_CLIENT_ID       --repo "${GITHUB_ORG}/${GITHUB_REPO}" --body "${APP_ID}"
  gh variable set AZURE_TENANT_ID       --repo "${GITHUB_ORG}/${GITHUB_REPO}" --body "${TENANT_ID}"
  gh variable set AZURE_SUBSCRIPTION_ID --repo "${GITHUB_ORG}/${GITHUB_REPO}" --body "${SUBSCRIPTION_ID}"
  gh variable set AZURE_RESOURCE_GROUP  --repo "${GITHUB_ORG}/${GITHUB_REPO}" --body "${RESOURCE_GROUP}"
  gh variable set AZURE_CONTAINER_APP   --repo "${GITHUB_ORG}/${GITHUB_REPO}" --body "${APP_NAME_AZ}"
  gh variable set ACR_NAME              --repo "${GITHUB_ORG}/${GITHUB_REPO}" --body "${ACR_NAME}"
  gh variable set IMAGE_NAME            --repo "${GITHUB_ORG}/${GITHUB_REPO}" --body "${IMAGE_NAME}"
  echo "    done"
else
  cat <<EOF

==========================================================
 gh CLI unavailable. Set these REPOSITORY VARIABLES by hand
 on ${GITHUB_ORG}/${GITHUB_REPO} -> Settings -> Secrets and
 variables -> Actions -> Variables:

   AZURE_CLIENT_ID       = ${APP_ID}
   AZURE_TENANT_ID       = ${TENANT_ID}
   AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}
   AZURE_RESOURCE_GROUP  = ${RESOURCE_GROUP}
   AZURE_CONTAINER_APP   = ${APP_NAME_AZ}
   ACR_NAME              = ${ACR_NAME}
   IMAGE_NAME            = ${IMAGE_NAME}
==========================================================
EOF
fi

cat <<EOF

==========================================================
 Bootstrap complete.

  App URL : https://${APP_FQDN}
  CMS     : https://${APP_FQDN}/admin
  Registry: ${ACR_LOGIN_SERVER}

 Next: create GitHub Environments 'dev' and 'prod' on
 ${GITHUB_ORG}/${GITHUB_REPO}, and add required reviewers to
 'prod'. Then push to main to trigger the pipeline.

 Tear down everything later with:
   az group delete --name ${RESOURCE_GROUP} --yes --no-wait
   az ad app delete --id ${APP_ID}
==========================================================
EOF
