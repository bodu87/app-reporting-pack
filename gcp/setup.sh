#!/bin/bash

SETTING_FILE="./settings.ini"
SCRIPT_PATH=$(readlink -f "$0" | xargs dirname)
SETTING_FILE="${SCRIPT_PATH}/settings.ini"

# changing the cwd to the script's contining folder so all pathes inside can be local to it
# (important as the script can be called via absolute path and as a nested path)
pushd $SCRIPT_PATH




while :; do
    case $1 in
  -s|--settings)
      shift
      SETTING_FILE=$1
      ;;
  *)
      break
    esac
  shift
done

REPOSITORY=$(git config -f $SETTING_FILE repository.name)
IMAGE_NAME=$(git config -f $SETTING_FILE repository.image)
REPOSITORY_LOCATION=$(git config -f $SETTING_FILE repository.location)
TOPIC=$(git config -f $SETTING_FILE pubsub.topic)
NAME=$(git config -f $SETTING_FILE config.name)

PROJECT_ID=$(gcloud config get-value project 2> /dev/null)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="csv(projectNumber)" | tail -n 1)
SERVICE_ACCOUNT=$PROJECT_NUMBER-compute@developer.gserviceaccount.com


enable_apis() {
  gcloud services enable compute.googleapis.com
  gcloud services enable artifactregistry.googleapis.com
  gcloud services enable run.googleapis.com
  gcloud services enable cloudresourcemanager.googleapis.com
  gcloud services enable iamcredentials.googleapis.com
  gcloud services enable cloudbuild.googleapis.com
  gcloud services enable cloudfunctions.googleapis.com
  gcloud services enable eventarc.googleapis.com
}


create_registry() {
  echo "Creating a repository in Artifact Repository"
  gcloud artifacts repositories create $REPOSITORY \
      --repository-format=Docker \
      --location=$REPOSITORY_LOCATION
}


build_docker_image() {
  echo "Building and pushing Docker image to Artifact Registry"
  gcloud builds submit --config=cloudbuild.yaml --substitutions=_REPOSITORY="docker",_IMAGE="$IMAGE_NAME",_REPOSITORY_LOCATION="$REPOSITORY_LOCATION" ./..
}


build_docker_image_gcr() {
  # NOTE: it's an alternative to build_docker_image if you want to use GCR instead of AR
  echo "Building and pushing Docker image to Container Registry"
  gcloud builds submit --config=cloudbuild-gcr.yaml --substitutions=_IMAGE="workload" ./workload-vm
}


set_iam_permissions() {
  echo "Setting up IAM permissions"
  gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$SERVICE_ACCOUNT --role=roles/storage.objectViewer
  gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$SERVICE_ACCOUNT --role=roles/artifactregistry.repoAdmin
  gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$SERVICE_ACCOUNT --role=roles/compute.admin
  gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$SERVICE_ACCOUNT --role=roles/monitoring.editor
}


create_topic() {
  TOPIC_EXISTS=$(gcloud pubsub topics list --filter="name.scope(topic):'$TOPIC'" --format="get(name)")
  if [[ ! -n $TOPIC_EXISTS ]]; then
    gcloud pubsub topics create $TOPIC
  fi
}

deploy_cf() {
  echo "Deploying Cloud Function"
  CF_REGION=$(git config -f $SETTING_FILE function.region)
  CF_NAME=$(git config -f $SETTING_FILE function.name)

  create_topic

  # create env.yaml from env.yaml.template if it doesn't exist
  if [ ! -f ./cloud-functions/create-vm/env.yaml ]; then
    echo "creating env.yaml"
    cp ./cloud-functions/create-vm/env.yaml.template ./cloud-functions/create-vm/env.yaml
  fi
  # initialize env.yaml - environment variables for CF:
  #   - docker image url
  url="$REPOSITORY_LOCATION-docker.pkg.dev/$PROJECT_ID/docker/$IMAGE_NAME"
  sed -i'.original' -e "s|#*[[:space:]]*DOCKER_IMAGE[[:space:]]*:[[:space:]]*.*$|DOCKER_IMAGE: $url|" ./cloud-functions/create-vm/env.yaml
  #   - GCE VM name (base)
  instance=$(git config -f $SETTING_FILE compute.name)
  sed -i'.original' -e "s|#*[[:space:]]*INSTANCE_NAME[[:space:]]*:[[:space:]]*.*$|INSTANCE_NAME: $instance|" ./cloud-functions/create-vm/env.yaml
  #   - GCE machine type
  machine_type=$(git config -f $SETTING_FILE compute.machine-type)
  sed -i'.original' -e "s|#*[[:space:]]*MACHINE_TYPE[[:space:]]*:[[:space:]]*.*$|MACHINE_TYPE: $machine_type|" ./cloud-functions/create-vm/env.yaml
  #   - GCE Region
  gce_region=$(git config -f $SETTING_FILE compute.region)
  sed -i'.original' -e "s|#*[[:space:]]*REGION[[:space:]]*:[[:space:]]*.*$|REGION: $gce_region|" ./cloud-functions/create-vm/env.yaml
  #   - GCE Zone
  gce_zone=$(git config -f $SETTING_FILE compute.zone)
  sed -i'.original' -e "s|#*[[:space:]]*ZONE[[:space:]]*:[[:space:]]*.*$|ZONE: $gce_zone|" ./cloud-functions/create-vm/env.yaml

  # deploy CF (pubsub triggered)
  gcloud functions deploy $CF_NAME \
      --trigger-topic=$TOPIC \
      --entry-point=createInstance \
      --runtime=nodejs18 \
      --timeout=540s \
      --region=$CF_REGION \
      --quiet \
      --gen2 \
      --env-vars-file ./cloud-functions/create-vm/env.yaml \
      --source=./cloud-functions/create-vm/
}


deploy_config() {
  echo 'Deploying config to GCS'
  gsutil mb -b on gs://$PROJECT_ID

  GCS_BASE_PATH=gs://$PROJECT_ID/$NAME
  gsutil -h "Content-Type:text/plain" cp ./../config.yaml $GCS_BASE_PATH/config.yaml
  gsutil -h "Content-Type:text/plain" cp ./../google-ads.yaml $GCS_BASE_PATH/google-ads.yaml
}

deploy_public_index() {
  echo 'Deploying index.html to GCS'

  gsutil mb -b on gs://${PROJECT_ID}-public
  gsutil iam ch -f allUsers:objectViewer gs://${PROJECT_ID}-public 2> /dev/null
  exitcode=$?
  if [ $exitcode -ne 0 ]; then
    echo "Could not add public access to public cloud bucket"
  fi

  GCS_BASE_PATH_PUBLIC=gs://${PROJECT_ID}-public/$NAME
  gsutil -h "Content-Type:text/plain" cp "${SCRIPT_PATH}/../one_click_deploy/index.html" $GCS_BASE_PATH_PUBLIC/index.html
}


get_run_data() {
  # arguments for the CF (to be passed via pubsub message and scheduler job's arguments):
  #   * project_id
  #   * machine_type
  #   * service_account
  #   * ads_config_uri
  #   * config_uri
  #   * docker_image
  GCS_BASE_PATH=gs://$PROJECT_ID/$NAME
  GCS_BASE_PATH_PUBLIC=gs://${PROJECT_ID}-public/$NAME
  # NOTE for the commented code:
  # currently deploy_cf target puts a docker image url into env.yaml for CF, so there's no need to pass an image url via arguments,
  # but if you want to support several images simultaneously (e.g. with different tags) then image url can be passed via message as:
  #    "docker_image": "'$REPOSITORY_LOCATION'-docker.pkg.dev/'$PROJECT_ID'/docker/'$IMAGE_NAME'",
  data='{
    "config_uri": "'$GCS_BASE_PATH'/config.yaml",
    "ads_config_uri": "'$GCS_BASE_PATH'/google-ads.yaml",
    "gcs_base_path_public": "'$GCS_BASE_PATH_PUBLIC'"
  }'
  echo $data
}

get_run_data_escaped() {
  local DATA=$(get_run_data)
  ESCAPED_DATA="$(echo "$DATA" | sed 's/"/\\"/g')"
  echo $ESCAPED_DATA
}


start() {
  # args for the cloud function (create-vm) passed via pub/sub event:
  #   * project_id - 
  #   * docker_image - a docker image url, can be CR or AR
  #       gcr.io/$PROJECT_ID/workload
  #       europe-docker.pkg.dev/$PROJECT_ID/docker/workload
  #   * service_account 
  # --message="{\"project_id\":\"$PROJECT_ID\", \"docker_image\":\"europe-docker.pkg.dev/$PROJECT_ID/docker/workload\", \"service_account\":\"$SERVICE_ACCOUNT\"}"

  local DATA=$(get_run_data)
  echo 'Publishing a pubsub with args: '$DATA
  gcloud pubsub topics publish $TOPIC --message="$DATA"

  # Check if there is a public bucket and index.html and echo the url
  INDEX_PATH="${PROJECT_ID}-public/$NAME"
  IS_INDEX_EXIST=$(gsutil ls gs://"$INDEX_PATH" | grep 'index.html' )
  if [[ -n $IS_INDEX_EXIST ]]; then
    GREEN='\033[0;32m'
    LIGHT_GREEN='\033[1;32m'
    NC='\033[0m'

    echo -e "${GREEN}[ * ] To access your new dashboard, click this link - ${LIGHT_GREEN}https://storage.googleapis.com/${INDEX_PATH}/index.html${NC}"
  fi
}


schedule_run() {
  JOB_NAME=$(git config -f $SETTING_FILE scheduler.name)
  REGION=$(git config -f $SETTING_FILE scheduler.region)
  SCHEDULE=$(git config -f $SETTING_FILE scheduler.schedule)
  SCHEDULE=${SCHEDULE:-"0 0 * * *"} # by default at midnight
  local DATA=$(get_run_data)
  echo 'Scheduling a job with args: '$DATA

  gcloud scheduler jobs delete $JOB_NAME --location $REGION --quiet

  gcloud scheduler jobs create pubsub $JOB_NAME \
    --schedule="$SCHEDULE" \
    --location=$REGION \
    --topic=$TOPIC \
    --message-body="$DATA" \
    --time-zone="Etc/UTC"
}


deploy_all() {
  enable_apis
  set_iam_permissions
  create_registry
  build_docker_image
  deploy_cf
  deploy_config
  schedule_run
}


for i in "$@"; do
  "$i"
  exitcode=$?
  if [ $exitcode -ne 0 ]; then
    echo "Breaking script as command '$i' failed"
    exit $exitcode
  fi
done

popd