#!/bin/bash

# ... (header and helper functions are unchanged) ...
set -eo pipefail
CONFIG_FILE="config.ini"
# MODIFICATION: The name of the Helm chart is now correct.
HELM_CHART_NAME="apigee-healthcheck-blackbox"

# ... (color and helper functions are unchanged) ...
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO] ${NC}$1"; }
warn() { echo -e "${YELLOW}[WARN] ${NC}$1"; }
error() { echo -e "${RED}[ERROR] ${NC}$1" >&2; exit 1; }
get_ini_value() { grep "^${2}" "$1" | cut -d '=' -f 2- | sed 's/^[ \t]*//;s/[ \t]*$//'; }


# --- 1. Load Configuration ---
info "Loading configuration from ${CONFIG_FILE}..."
if [ ! -f "$CONFIG_FILE" ]; then
    error "${CONFIG_FILE} not found. Please ensure it exists and is configured."
fi

HELM_RELEASE_NAME=$(get_ini_value "$CONFIG_FILE" "release_name")
HELM_NAMESPACE=$(get_ini_value "$CONFIG_FILE" "namespace")
GCP_PROJECT_ID=$(get_ini_value "$CONFIG_FILE" "project_id")

# ... (validation section is unchanged) ...
info "Validating prerequisites..."
command -v gcloud >/dev/null 2>&1 || error "'gcloud' command not found."
command -v kubectl >/dev/null 2>&1 || error "'kubectl' command not found."
if [[ -z "$GCP_PROJECT_ID" || "$GCP_PROJECT_ID" == "your-gcp-project-id" ]]; then
    error "GCP Project ID is not set in ${CONFIG_FILE}."
fi
gcloud config set project "$GCP_PROJECT_ID"

# Define the names for the Google Service Account (GSA) and Kubernetes Service Account (KSA)
GSA_NAME="apigee-cronjob-sa"
GSA_EMAIL="${GSA_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
# MODIFICATION: KSA name is now derived using the correct chart name
KSA_NAME="${HELM_RELEASE_NAME}-${HELM_CHART_NAME}"

info "Configuration:
  GCP Project ID:         ${GCP_PROJECT_ID}
  Helm Release:           ${HELM_RELEASE_NAME}
  Helm Namespace:         ${HELM_NAMESPACE}
  Google SA (GSA):        ${GSA_NAME}
  Kubernetes SA (KSA):    ${KSA_NAME}"
echo ""

# ... (rest of the script for creating GSA, granting roles, linking, and annotating is unchanged) ...
info "Step 1: Ensuring Google Service Account (GSA) '${GSA_NAME}' exists..."
if ! gcloud iam service-accounts describe "$GSA_EMAIL" &>/dev/null; then
    info "GSA not found. Creating it..."
    gcloud iam service-accounts create "$GSA_NAME" --display-name="Service Account for Apigee Monitoring CronJob"
else
    info "GSA '${GSA_NAME}' already exists."
fi; echo ""

info "Step 2: Granting 'Artifact Registry Reader' role to GSA..."
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" --member="serviceAccount:${GSA_EMAIL}" --role="roles/artifactregistry.reader" --condition=None
info "Role granted successfully."; echo ""

info "Step 3: Linking GSA to Kubernetes Service Account (KSA)..."
if ! kubectl get serviceaccount "$KSA_NAME" --namespace "$HELM_NAMESPACE" &>/dev/null; then
    error "Kubernetes Service Account '${KSA_NAME}' not found in namespace '${HELM_NAMESPACE}'."
fi
info "Allowing KSA '${KSA_NAME}' to impersonate GSA '${GSA_EMAIL}'..."
gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" --role "roles/iam.workloadIdentityUser" --member "serviceAccount:${GCP_PROJECT_ID}.svc.id.goog[${HELM_NAMESPACE}/${KSA_NAME}]"
info "IAM binding for Workload Identity created."; echo ""

info "Step 4: Annotating KSA with the GSA email..."
kubectl annotate serviceaccount "$KSA_NAME" --namespace "$HELM_NAMESPACE" "iam.gke.io/gcp-service-account=${GSA_EMAIL}" --overwrite
info "KSA '${KSA_NAME}' annotated successfully."; echo ""

info "${GREEN}Workload Identity setup is complete!${NC}"
# ... (Next steps message is unchanged) ...