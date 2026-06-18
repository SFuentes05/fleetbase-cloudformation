#!/usr/bin/env bash
# Deploy or update Fleetbase application on EC2 via SSM (used by CI/CD).
set -euo pipefail

INSTANCE_ID="${1:?EC2 instance ID required}"
AWS_REGION="${AWS_REGION:-us-east-1}"
FLEETBASE_REF="${FLEETBASE_REF:-main}"
INSTALL_DIR="/opt/fleetbase"

read -r -d '' COMMANDS <<EOF || true
set -euo pipefail
cd ${INSTALL_DIR}
git fetch --all --tags
git checkout ${FLEETBASE_REF} 2>/dev/null || git pull origin ${FLEETBASE_REF}
docker compose pull application queue scheduler socket httpd || true
docker compose build console
docker compose up -d application queue scheduler socket console httpd
for i in \$(seq 1 20); do
  docker compose exec -T application php artisan --version >/dev/null 2>&1 && break
  sleep 5
done
docker compose exec -T application bash -c "./deploy.sh"
echo "Deploy complete"
EOF

PARAMS="$(jq -n --arg cmd "$COMMANDS" '{commands: [$cmd]}')"

COMMAND_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "Fleetbase application deploy" \
  --parameters "$PARAMS" \
  --region "$AWS_REGION" \
  --query 'Command.CommandId' \
  --output text)"

echo "SSM command: $COMMAND_ID"
aws ssm wait command-executed \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' \
  --output text
