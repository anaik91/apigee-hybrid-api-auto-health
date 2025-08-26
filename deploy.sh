#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -eo pipefail

# --- Configuration ---
CONFIG_FILE="config.ini"

# --- Colors for Output ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO] ${NC}$1"
}
warn() {
    echo -e "${YELLOW}[WARN] ${NC}$1"
}
error() {
    echo -e "${RED}[ERROR] ${NC}$1" >&2
    exit 1
}

# --- Helper function to read INI file ---
get_ini_value() {
    local file="$1"
    local key="$2"
    grep "^${key}" "$file" | cut -d '=' -f 2- | sed 's/^[ \t]*//;s/[ \t]*$//'
}

# --- 1. Load Configuration and Set Defaults ---
info "Loading configuration from ${CONFIG_FILE}..."

# Set default values
GCP_PROJECT_ID=""
GCP_REGION="us-central1"
ARTIFACT_REGISTRY_NAME="apigee-monitoring-repo"
IMAGE_NAME="apigee-target-generator"
IMAGE_TAG="v1.0.0"
HELM_RELEASE_NAME="apigee-monitor"
HELM_CHART_PATH="."
HELM_NAMESPACE="monitoring"
APIGEE_INGRESS_SERVICE="apigee-ingressgateway"

if [ ! -f "$CONFIG_FILE" ]; then
    warn "${CONFIG_FILE} not found. Using default values."
else
    # Read from config file and override defaults if value exists
    GCP_PROJECT_ID=$(get_ini_value "$CONFIG_FILE" "project_id")
    GCP_REGION=$(get_ini_value "$CONFIG_FILE" "region")
    ARTIFACT_REGISTRY_NAME=$(get_ini_value "$CONFIG_FILE" "artifact_registry_name")
    IMAGE_NAME=$(get_ini_value "$CONFIG_FILE" "image_name")
    IMAGE_TAG=$(get_ini_value "$CONFIG_FILE" "tag")
    HELM_RELEASE_NAME=$(get_ini_value "$CONFIG_FILE" "release_name")
    HELM_CHART_PATH=$(get_ini_value "$CONFIG_FILE" "chart_path")
    HELM_NAMESPACE=$(get_ini_value "$CONFIG_FILE" "namespace")
    APIGEE_INGRESS_SERVICE=$(get_ini_value "$CONFIG_FILE" "apigee_ingress_service")
fi

# --- 2. Validate Prerequisites and Configuration ---
info "Validating prerequisites..."
command -v gcloud >/dev/null 2>&1 || error "'gcloud' command not found. Please install the Google Cloud SDK."
command -v helm >/dev/null 2>&1 || error "'helm' command not found. Please install Helm."

if [[ -z "$GCP_PROJECT_ID" || "$GCP_PROJECT_ID" == "your-gcp-project-id" ]]; then
    error "GCP Project ID is not set. Please update 'project_id' in ${CONFIG_FILE}."
fi

# Construct the full image URL for Artifact Registry
ARTIFACT_REGISTRY_URL="${GCP_REGION}-docker.pkg.dev"
FULL_IMAGE_URL="${ARTIFACT_REGISTRY_URL}/${GCP_PROJECT_ID}/${ARTIFACT_REGISTRY_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"
IMAGE_URL_NO_TAG="${ARTIFACT_REGISTRY_URL}/${GCP_PROJECT_ID}/${ARTIFACT_REGISTRY_NAME}/${IMAGE_NAME}"

info "Deployment details:
  Project ID:             ${GCP_PROJECT_ID}
  Region:                 ${GCP_REGION}
  Artifact Registry:      ${ARTIFACT_REGISTRY_NAME}
  Full Docker Image:      ${FULL_IMAGE_URL}
  Helm Release:           ${HELM_RELEASE_NAME}
  Helm Chart Path:        ${HELM_CHART_PATH}
  Helm Namespace:         ${HELM_NAMESPACE}"
echo ""

# --- 3. Configure GCP and Authenticate ---
info "Step 1: Configuring gcloud and Docker authentication..."
gcloud config set project "$GCP_PROJECT_ID"

# Check if the Artifact Registry repository exists, create if not
if ! gcloud artifacts repositories describe "$ARTIFACT_REGISTRY_NAME" --location="$GCP_REGION" &>/dev/null; then
    info "Artifact Registry repository '${ARTIFACT_REGISTRY_NAME}' not found. Creating it..."
    gcloud artifacts repositories create "$ARTIFACT_REGISTRY_NAME" \
        --repository-format=docker \
        --location="$GCP_REGION" \
        --description="Repository for Apigee monitoring tools"
else
    info "Artifact Registry repository '${ARTIFACT_REGISTRY_NAME}' already exists."
fi

gcloud auth configure-docker "$ARTIFACT_REGISTRY_URL"
info "gcloud configuration complete."
echo ""

# --- 4. Build Docker Image with Google Cloud Build ---
info "Step 2: Building Docker image with Google Cloud Build..."
if [ ! -d "python-script" ] || [ ! -f "python-script/Dockerfile" ]; then
    error "The 'python-script' directory with its Dockerfile was not found."
fi

gcloud builds submit ./python-script --tag "$FULL_IMAGE_URL"
info "Docker image built and pushed successfully: ${FULL_IMAGE_URL}"
echo ""

# --- 5. Deploy Helm Chart ---
info "Step 3: Deploying the Helm chart..."

# Validate that the helm chart path is valid
if [ ! -f "${HELM_CHART_PATH}/Chart.yaml" ]; then
    error "Helm chart not found at path '${HELM_CHART_PATH}'. Make sure a 'Chart.yaml' file exists there."
fi

helm upgrade --install "$HELM_RELEASE_NAME" "$HELM_CHART_PATH" \
    --namespace "$HELM_NAMESPACE" \
    --create-namespace \
    --set cronjob.image.repository="$IMAGE_URL_NO_TAG" \
    --set cronjob.image.tag="$IMAGE_TAG" \
    --set cronjob.apigeeIngressService="$APIGEE_INGRESS_SERVICE"

info "Helm chart '${HELM_RELEASE_NAME}' deployed successfully to namespace '${HELM_NAMESPACE}'."
echo ""

# --- Success ---
info "${GREEN}Deployment Complete!${NC}

Next Steps:
1. Wait for the CronJob to run (check with 'kubectl get jobs -n ${HELM_NAMESPACE}').
2. Once a job has completed, a targets file will be available in the PVC.
3. Configure your Prometheus instance to scrape the Blackbox Exporter and read the targets
   from the PVC named '${HELM_RELEASE_NAME}-prometheus-apigee-exporter-pvc'."