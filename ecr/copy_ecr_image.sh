#!/usr/bin/env bash
set -euo pipefail

SOURCE_PROFILE=nri-develop
SOURCE_REGION=us-east-1
SOURCE_REPO=minio-migrator
SOURCE_TAG=1264-merge
DEST_PROFILE=nri-customer
DEST_REGION=us-east-2
#DEST_PROFILE=nri-develop
#DEST_REGION=us-east-1
DEST_REPO=${DEST_REPO:-${SOURCE_REPO}}
DEST_TAG=${DEST_TAG:-${SOURCE_TAG}}


SOURCE_ACCOUNT=$(aws sts get-caller-identity --profile $SOURCE_PROFILE | jq -r .Account)
aws ecr get-login-password --region $SOURCE_REGION --profile $SOURCE_PROFILE \
| docker login --username AWS --password-stdin $SOURCE_ACCOUNT.dkr.ecr.$SOURCE_REGION.amazonaws.com

DEST_ACCOUNT=$(aws sts get-caller-identity --profile $DEST_PROFILE | jq -r .Account)
aws ecr get-login-password --region $DEST_REGION --profile $DEST_PROFILE \
| docker login --username AWS --password-stdin $DEST_ACCOUNT.dkr.ecr.$DEST_REGION.amazonaws.com

docker pull "$SOURCE_ACCOUNT.dkr.ecr.$SOURCE_REGION.amazonaws.com/${SOURCE_REPO}:${SOURCE_TAG}"
docker tag  "$SOURCE_ACCOUNT.dkr.ecr.$SOURCE_REGION.amazonaws.com/${SOURCE_REPO}:${SOURCE_TAG}" \
            "$DEST_ACCOUNT.dkr.ecr.$DEST_REGION.amazonaws.com/${DEST_REPO}:${DEST_TAG}"
docker push "$DEST_ACCOUNT.dkr.ecr.$DEST_REGION.amazonaws.com/${DEST_REPO}:${DEST_TAG}"

