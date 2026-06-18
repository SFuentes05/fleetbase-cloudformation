#!/usr/bin/env bash
# One-time setup: GitHub Actions OIDC trust for AWS deployments.
#
# Usage:
#   GITHUB_ORG=your-org GITHUB_REPO=your-repo ./scripts/setup-github-oidc.sh
#
# Requires: aws cli, jq

set -euo pipefail

GITHUB_ORG="${GITHUB_ORG:?Set GITHUB_ORG}"
GITHUB_REPO="${GITHUB_REPO:?Set GITHUB_REPO}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ROLE_NAME="${ROLE_NAME:-GitHubActionsFleetbaseDeploy}"
POLICY_NAME="${POLICY_NAME:-FleetbaseDeployPolicy}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" &>/dev/null; then
  echo "Creating GitHub OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03fa0217a5d6397c7a7a5b5c5c5
fi

TRUST_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF
)"

DEPLOY_POLICY="$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:*",
        "ec2:*",
        "ecs:*",
        "ecr:*",
        "elasticloadbalancing:*",
        "rds:*",
        "elasticache:*",
        "s3:*",
        "cloudfront:*",
        "acm:*",
        "route53:*",
        "sqs:*",
        "logs:*",
        "cloudwatch:*",
        "ssm:*",
        "secretsmanager:*",
        "iam:PassRole",
        "iam:GetRole",
        "iam:CreateRole",
        "iam:AttachRolePolicy",
        "iam:PutRolePolicy",
        "iam:TagRole",
        "lambda:*",
        "application-autoscaling:*",
        "servicediscovery:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)"

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY"
fi

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
  VERSIONS="$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
  for v in $VERSIONS; do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v" || true
  done
  aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "$DEPLOY_POLICY" --set-as-default
else
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "$DEPLOY_POLICY"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true

echo ""
echo "Add this GitHub Actions secret/variable:"
echo "  AWS_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "  AWS_REGION=${AWS_REGION}"
