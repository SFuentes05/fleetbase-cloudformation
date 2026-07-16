#!/bin/bash
# Reconfigure a running Fleetbase EC2 instance for a new domain.
# Usage: ROOT_DOMAIN=unitedsoftware.lat CONSOLE_SUB=fleet API_SUB=api ./scripts/switch-domain.sh <instance-id>

set -euo pipefail

INSTANCE_ID="${1:?EC2 instance ID required}"
AWS_REGION="${AWS_REGION:-us-east-1}"

ROOT_DOMAIN="${ROOT_DOMAIN:-unitedsoftware.lat}"
CONSOLE_SUB="${CONSOLE_SUB:-fleet}"
API_SUB="${API_SUB:-api}"
ADMIN_EMAIL="${ADMIN_EMAIL:-sfuentes@assetmg.tech}"

SCRIPT=$(cat <<SCRIPT
set -euo pipefail
export AWS_REGION=${AWS_REGION}
export ROOT_DOMAIN=${ROOT_DOMAIN}
export CONSOLE_SUB=${CONSOLE_SUB}
export API_SUB=${API_SUB}
export ADMIN_EMAIL=${ADMIN_EMAIL}
aws s3 cp s3://ulogistics-production-uploads-828885964402/scripts/fix-production.sh /tmp/fix.sh --region ${AWS_REGION}
bash /tmp/fix.sh
sudo sed -i "s/server_name .*/server_name ${CONSOLE_SUB}.${ROOT_DOMAIN};/" /etc/nginx/sites-available/fleetbase || true
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d ${CONSOLE_SUB}.${ROOT_DOMAIN} -d ${API_SUB}.${ROOT_DOMAIN} --non-interactive --agree-tos -m ${ADMIN_EMAIL} --redirect || true
echo "Done. Console: https://${CONSOLE_SUB}.${ROOT_DOMAIN}  API: https://${API_SUB}.${ROOT_DOMAIN}"
SCRIPT
)

PARAMS="$(jq -n --arg cmd "$SCRIPT" '{commands: [$cmd]}')"
COMMAND_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 900 \
  --parameters "$PARAMS" \
  --region "$AWS_REGION" \
  --query 'Command.CommandId' \
  --output text)"

echo "SSM command: $COMMAND_ID"
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --region "$AWS_REGION"
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query '[Status, StandardOutputContent]' \
  --output text
