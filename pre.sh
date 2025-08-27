#!/bin/bash

gcloud services enable secretmanager.googleapis.com
gcloud secrets create dockerhub-pat --replication-policy="automatic" --quiet

# Replace 'YOUR_DOCKERHUB_PAT' with your actual token
echo -n "$DOCKERHUB_PAT" | gcloud secrets versions add dockerhub-pat --data-file=-

PROJECT_NUMBER=$(gcloud projects describe "$(gcloud config get-value project)" --format='value(projectNumber)')
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

gcloud secrets add-iam-policy-binding dockerhub-pat \
  --member="serviceAccount:${CLOUDBUILD_SA}" \
  --role="roles/secretmanager.secretAccessor"