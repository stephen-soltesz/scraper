#!/bin/bash

# A script that builds and deploys scraper containers and their associated
# storage. Meant to be called from the root directory of the repo or by Travis
# from wherever travis calls things. In the Travis case, it is expected that $2
# will equal travis.

USAGE="$0 [production|staging|arbitrary-string-sandbox] travis?"
if [[ -n "$2" ]] && [[ "$2" != travis ]]; then
  echo The second argument can only be the word travis or nothing at all.
  echo $USAGE
  exit 1
fi

set -e
set -x

if [[ $2 == travis ]]; then
  cd $TRAVIS_BUILD_DIR
  GIT_COMMIT=${TRAVIS_COMMIT}
else
  GIT_COMMIT=$(git log -n 1 | head -n 1 | awk '{print $2}')
fi

source "${HOME}/google-cloud-sdk/path.bash.inc"

if [[ -e deployment ]] || [[ -e claims ]]; then
  echo "You must remove existing deployment/ and claims/ directories"
  exit 1
fi
mkdir deployment
mkdir claims

# Fills in deployment templates.
function fill_in_templates() {
  USAGE="$0 <pattern> <storage_size> <claims_dir> <deploy_dir>"
  PATTERN=${1:?Please provide a pattern for mlabconfig: $USAGE}
  GIGABYTES=${2:?Please give an integer number of gigabytes: $USAGE}
  CLAIMS=${3:?Please give a directory for the claims templates: $USAGE}
  DEPLOY=${4:?Please give a directory for the deployment templates: $USAGE}

  ./operator/plsync/mlabconfig.py \
      --format=scraper_kubernetes \
      --template_input=k8s/deploy_template.yml \
      --template_output=${DEPLOY}/deploy-{{site_safe}}-{{node_safe}}-{{experiment_safe}}-{{rsync_module_safe}}.yml \
      --select="${PATTERN}"

  ./operator/plsync/mlabconfig.py \
      --format=scraper_kubernetes \
      --template_input=k8s/claim_template.yml \
      --template_output=${CLAIMS}/claim-{{site_safe}}-{{node_safe}}-{{experiment_safe}}-{{rsync_module_safe}}.yml \
    --select="${PATTERN}"

  ./travis/substitute_values.sh ${CLAIMS} GIGABYTES ${GIGABYTES}
}

if [[ "$1" == staging ]]
then
  # no mlab4s until more bugs are worked out
  #fill_in_templates 'mlab4' 11
  #fill_in_templates 'ndt.*mlab4' 110
  cat operator/plsync/canary_machines.txt | (
      # Disable -x to prevent build log spam
      set +x
      while read
      do
        fill_in_templates "${REPLY}" 11 claims deployment
        fill_in_templates "ndt.*${REPLY}" 110 claims deployment
      done
      # Re-enable -x to aid debugging
      set -x)
  PROJECT=mlab-staging
  BUCKET=scraper-mlab-staging
  DATASTORE_NAMESPACE=scraper
  CLUSTER=scraper-cluster
  ZONE=us-central1-a
else
  echo "Bad argument to $0"
  exit 1
fi

./travis/substitute_values.sh deployment \
    IMAGE_URL gcr.io/${PROJECT}/github-m-lab-scraper:${GIT_COMMIT} \
    GCS_BUCKET ${BUCKET} \
    NAMESPACE ${DATASTORE_NAMESPACE} \
    GITHUB_COMMIT http://github.com/m-lab/scraper/tree/${GIT_COMMIT}

./travis/build_and_push_container.sh \
    gcr.io/${PROJECT}/github-m-lab-scraper:${GIT_COMMIT} ${PROJECT}

gcloud --project=${PROJECT} container clusters get-credentials ${CLUSTER} --zone=${ZONE}

kubectl apply -f k8s/namespace.yml
kubectl apply -f k8s/storage-class.yml

CLAIMSOUT=$(mktemp claims.XXXXXX)
kubectl apply -f claims/ > ${CLAIMSOUT} || (cat ${CLAIMSOUT} && exit 1)
echo Applied $(wc -l ${CLAIMSOUT} | awk '{print $1}') claims

DEPLOYOUT=$(mktemp deployments.XXXXXX)
kubectl apply -f deployment/ > ${DEPLOYOUT} || (cat ${DEPLOYOUT} && exit 1)
echo Applied $(wc -l ${DEPLOYOUT} | awk '{print $1}') deployments

echo kubectl returned success from "'$0 $@'" for all operations.
echo Suppressed output is appended below to aid future debugging:
echo Output of successful "'kubectl apply -f claims/'":
cat ${CLAIMSOUT}
rm ${CLAIMSOUT}
echo Output of successful "'kubectl apply -f deployment/'":
cat ${DEPLOYOUT}
rm ${DEPLOYOUT}
