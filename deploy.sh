#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -eo pipefail

# --- Configuration ---
CONFIG_FILE="config.ini"

# --- Colors for Output ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO] ${NC}$1"; }
warn() { echo -e "${YELLOW}[WARN] ${NC}$1"; }
error() { echo -e "${RED}[ERROR] ${NC}$1" >&2; exit 1; }
# --- Helper function to read INI file ---
get_ini_value() {
    local file="$1"
    local key="$2"
    # Use awk for robust key-value parsing.
    # -F sets the field separator to a flexible pattern: an equals sign
    #   surrounded by any amount of whitespace.
    # It checks if the first field ($1) exactly matches the provided key,
    # then prints the second field ($2), which is the value.
    awk -F '[[:space:]]*=[[:space:]]*' -v k="$key" \
        '$1 == k {print $2; exit}' "$file"
}

# --- 1. Load Configuration ---
info "Loading configuration from ${CONFIG_FILE}..."
if [ ! -f "$CONFIG_FILE" ]; then
    error "${CONFIG_FILE} not found. Create it from config.ini.example."
fi

# ... (Read all values from config file - same as before) ...
REGISTRY_TYPE=$(get_ini_value "$CONFIG_FILE" "type")
DOCKERHUB_USERNAME=$(get_ini_value "$CONFIG_FILE" "username")
DOCKERHUB_SECRET_ID=$(get_ini_value "$CONFIG_FILE" "secret_manager_secret_id")
GCP_PROJECT_ID=$(get_ini_value "$CONFIG_FILE" "project_id")
GCP_REGION=$(get_ini_value "$CONFIG_FILE" "region")
GCP_REPO_NAME=$(get_ini_value "$CONFIG_FILE" "repository_name")
IMAGE_NAME=$(get_ini_value "$CONFIG_FILE" "name")
echo "IMAGE_NAME ----> $IMAGE_NAME "
IMAGE_TAG=$(get_ini_value "$CONFIG_FILE" "tag")
HELM_RELEASE_NAME=$(get_ini_value "$CONFIG_FILE" "release_name")
HELM_CHART_PATH=$(get_ini_value "$CONFIG_FILE" "chart_path")
HELM_NAMESPACE=$(get_ini_value "$CONFIG_FILE" "namespace")
APIGEE_INGRESS_SERVICE=$(get_ini_value "$CONFIG_FILE" "apigee_ingress_service")


# --- 2. Validate Prerequisites and Construct Image URL ---
info "Validating prerequisites and configuration..."
command -v helm >/dev/null 2>&1 || error "'helm' command not found."
command -v gcloud >/dev/null 2>&1 || error "'gcloud' command not found."

if [ "$REGISTRY_TYPE" == "artifact_registry" ]; then
    # ... (Artifact Registry logic is the same) ...
    if [[ -z "$GCP_PROJECT_ID" || "$GCP_PROJECT_ID" == "your-gcp-project-id" ]]; then
        error "GCP Project ID is not set in ${CONFIG_FILE} for registry type 'artifact_registry'."
    fi
    ARTIFACT_REGISTRY_URL="${GCP_REGION}-docker.pkg.dev"
    FULL_IMAGE_URL="${ARTIFACT_REGISTRY_URL}/${GCP_PROJECT_ID}/${GCP_REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"
    IMAGE_URL_NO_TAG="${ARTIFACT_REGISTRY_URL}/${GCP_PROJECT_ID}/${GCP_REPO_NAME}/${IMAGE_NAME}"

elif [ "$REGISTRY_TYPE" == "docker_hub" ]; then
    # Docker Hub validation
    if [[ -z "$DOCKERHUB_USERNAME" || "$DOCKERHUB_USERNAME" == "your_dockerhub_username" ]]; then
        error "Docker Hub username is not set in ${CONFIG_FILE}."
    fi
    if [[ -z "$DOCKERHUB_SECRET_ID" ]]; then
        error "Docker Hub 'secret_manager_secret_id' is not set in ${CONFIG_FILE}."
    fi
    FULL_IMAGE_URL="${DOCKERHUB_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"
    IMAGE_URL_NO_TAG="${DOCKERHUB_USERNAME}/${IMAGE_NAME}"
else
    error "Invalid registry 'type' in ${CONFIG_FILE}."
fi

# ... (Info display is the same) ...
info "Deployment details:
  Registry Type:          ${REGISTRY_TYPE}
  Full Docker Image:      ${FULL_IMAGE_URL}
  Helm Release:           ${HELM_RELEASE_NAME}
  Helm Chart Path:        ${HELM_CHART_PATH}
  Helm Namespace:         ${HELM_NAMESPACE}"
echo ""

# --- 3. Authenticate and Prepare ---
info "Step 1: Preparing registry..."
if [ "$REGISTRY_TYPE" == "artifact_registry" ]; then
    gcloud config set project "$GCP_PROJECT_ID"
    # ... (Artifact Registry repo creation logic is the same) ...
    if ! gcloud artifacts repositories describe "$GCP_REPO_NAME" --location="$GCP_REGION" &>/dev/null; then
        info "Creating Artifact Registry repository '${GCP_REPO_NAME}'..."
        gcloud artifacts repositories create "$GCP_REPO_NAME" --repository-format=docker --location="$GCP_REGION" --description="Repo for monitoring tools"
    fi
    info "Using Artifact Registry repository '${GCP_REPO_NAME}'."

elif [ "$REGISTRY_TYPE" == "docker_hub" ]; then
    info "Using Docker Hub. Prerequisites (Secret Manager) are assumed to be complete."
    # No local auth needed, Cloud Build handles it.
fi
echo ""

# --- 4. Build and Push Docker Image via Cloud Build ---
info "Step 2: Building and pushing Docker image with Google Cloud Build..."
if [ ! -d "python-script" ] || [ ! -f "python-script/Dockerfile" ]; then
    error "The 'python-script' directory with its Dockerfile was not found."
fi

if [ "$REGISTRY_TYPE" == "artifact_registry" ]; then
    gcloud builds submit ./python-script --tag "$FULL_IMAGE_URL"

elif [ "$REGISTRY_TYPE" == "docker_hub" ]; then
    if [ ! -f "cloudbuild.yaml" ]; then
        error "'cloudbuild.yaml' is required for pushing to Docker Hub but was not found."
    fi
    info "Submitting build using cloudbuild.yaml..."
    gcloud builds submit . --config=cloudbuild.yaml \
        --substitutions=_FULL_IMAGE_URL="${FULL_IMAGE_URL}",_DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME}",_SECRET_ID="${DOCKERHUB_SECRET_ID}"
fi
info "Image build and push process completed successfully."
echo ""


# --- 5. Deploy Helm Chart ---
# This part remains exactly the same
info "Step 3: Deploying the Helm chart..."
if [ ! -f "${HELM_CHART_PATH}/Chart.yaml" ]; then
    error "Helm chart not found at path '${HELM_CHART_PATH}'."
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
# ... (Success message is the same) ...
info "${GREEN}Deployment Complete!${NC}"