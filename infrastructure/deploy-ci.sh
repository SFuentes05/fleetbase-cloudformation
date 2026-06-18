#!/usr/bin/env bash
# Non-interactive CloudFormation deploy for CI/CD.
# Usage: ./deploy-ci.sh <stack-name> <parameters-file> [region]

set -euo pipefail

STACK_NAME="${1:?stack name required}"
PARAMS_FILE="${2:?parameters file required}"
AWS_REGION="${3:-us-east-1}"
TEMPLATE="${TEMPLATE:-infrastructure/template.yaml}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: $TEMPLATE not found."
  exit 1
fi

aws cloudformation validate-template \
  --template-body "file://$TEMPLATE" \
  --region "$AWS_REGION"

if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" &>/dev/null; then
  echo "Updating stack $STACK_NAME..."
  aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://$TEMPLATE" \
    --parameters "file://$PARAMS_FILE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$AWS_REGION"
  aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
else
  echo "Creating stack $STACK_NAME..."
  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://$TEMPLATE" \
    --parameters "file://$PARAMS_FILE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$AWS_REGION"
  aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
fi

echo "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table
