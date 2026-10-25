export PROJECT_ID="divvy-project-512716"   # replace with the exact ID from the list
export REGION="us-central1"
export BUCKET="divvy-raw-srv"
export POLLER_SA="divvy-poller-sa@${PROJECT_ID}.iam.gserviceaccount.com"
export SCHED_SA="divvy-scheduler-sa@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project $PROJECT_ID

gcloud billing projects describe $PROJECT_ID

gcloud services enable cloudfunctions.googleapis.com run.googleapis.com \
  cloudbuild.googleapis.com cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com storage.googleapis.com

gcloud services list --enabled

source setup.sh
echo $PROJECT_ID $BUCKET

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="user:rpillay@uchicago.edu" --role="roles/editor"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="user:rvishwamitra@uchicago.edu" --role="roles/editor"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="user:varunn5@uchicago.edu" --role="roles/editor"