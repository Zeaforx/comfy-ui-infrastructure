export PROJECT_ID=$(gcloud config get-value project)
export SA_NAME="comfyui-deployer"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Create the service account first
gcloud iam service-accounts create $SA_NAME --display-name="ComfyUI Deployer"

# Then assign roles
for role in roles/compute.instanceAdmin.v1 roles/iam.serviceAccountUser roles/compute.networkAdmin roles/storage.admin; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SA_EMAIL" \
    --role="$role"
done