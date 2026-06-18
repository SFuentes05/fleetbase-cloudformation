#!/usr/bin/env bash
# Create ECR repositories for custom Fleetbase images.
# Run once before first app deploy.

set -euo pipefail

PROJECT="${PROJECT:-ulogistics}"
AWS_REGION="${AWS_REGION:-us-east-1}"

for repo in api events scheduler socket; do
  name="${PROJECT}/${repo}"
  if aws ecr describe-repositories --repository-names "$name" --region "$AWS_REGION" &>/dev/null; then
    echo "ECR repo exists: $name"
  else
    echo "Creating ECR repo: $name"
    aws ecr create-repository \
      --repository-name "$name" \
      --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 \
      --region "$AWS_REGION"
  fi
done

echo "Done. Image URIs:"
aws ecr describe-repositories \
  --region "$AWS_REGION" \
  --query "repositories[?starts_with(repositoryName, '${PROJECT}/')].repositoryUri" \
  --output text
