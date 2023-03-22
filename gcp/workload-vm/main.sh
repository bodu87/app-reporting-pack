#!/bin/bash

LOG_NAME=arp-vm

echo "Starting entrypoint script"

echo "--- Test ---"
echo "All Instance Metadata - $(curl "http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=true&alt=text" -H "Metadata-Flavor: Google")"

# Fetch GCP project_id from Metadata service and set it via gcloud
project_id=$(curl -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/project/project-id -s)
echo "Detected project id from metadata server: $project_id"
gcloud config set project $project_id

# Fetch config uris fro the current instance metadata
config_uri=$(curl -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/attributes/config_uri -s --fail)
if [ -z "$config_uri" ]; then
  config_uri="config.yaml" # by default we assume a local config (inside the current container)
  echo $config_uri
fi

ads_config_uri=$(curl -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/attributes/ads_config_uri -s --fail)
if [ -z "$ads_config_uri" ]; then
  ads_config_uri="google-ads.yaml"
  echo $ads_config_uri
fi

gcloud logging write $LOG_NAME "[$(hostname)] Starting ARP application (config: $config_uri, google-ads-config: $ads_config_uri)"

# run ARP
#./run-docker.sh "google_ads_queries/*/*.sql" "bq_queries" "$ads_config_uri" "$config_uri"
# TODO: --backfill, --legacy
./run-local.sh --quiet --config $config_uri --google-ads-config $ads_config_uri
exitcode=$?
if [ $exitcode -ne 0 ]; then
  gcloud logging write $LOG_NAME "[$(hostname)] ARP application has finished execution with an error" --severity ERROR
else
  gcloud logging write $LOG_NAME "[$(hostname)] ARP application has finished execution successfully"
fi

# Create URL for dashboard with Linking API
dashboard_url=$(./../../scripts/create_dashboard.sh -L)

# Update index.html with newly created URL and upload to gcs
if [ -n "$dashboard_url" ]; then
  gcs_base_path_public=$(curl -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/attributes/gcs_base_path_public -s --fail)
  echo "{\"dashboardUrl\":\"$dashboard_url\"}" > dashboard.json
  gsutil -h "Content-Type:text/plain" cp dashboard.json $gcs_base_path_public/dashboard.json
fi

# Check if index.html exists in the bucket. If so - create and upload dashboard.json

gcs_base_path_public=$(curl -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/attributes/gcs_base_path_public -s --fail)
INDEX_EXISTS="$gcs_base_path_public/index.html"

if [[ $INDEX_EXISTS -eq 1 ]]; then
  dashboard_url=$(./../../scripts/create_dashboard.sh -L)
  echo "{\"dashboardUrl\":\"$dashboard_url\"}" > dashboard.json
  gsutil -h "Content-Type:application/json" cp dashboard.json $gcs_base_path_public/dashboard.json
fi

# Delete the VM (fetch a custom metadata key, it can be absent, so returns 404 - handling it with --fail options)
delete_vm=$(curl -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/attributes/delete_vm -s --fail)
echo "Delete VM: $delete_vm"
if [[ "$delete_vm" = 'TRUE' ]]; then
    gcp_zone=$(curl -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/zone -s | cut -d/ -f4)
    gcloud compute instances delete $(hostname) --zone ${gcp_zone}
fi

gcloud logging write $LOG_NAME "[$(hostname)] Docker entrypoint script completed"
echo "Entrypoint script completed"