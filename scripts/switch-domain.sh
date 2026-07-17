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
S3_BUCKET="${S3_BUCKET:-ulogistics-production-uploads-828885964402}"

REMOTE_SCRIPT="$(mktemp)"
trap 'rm -f "$REMOTE_SCRIPT"' EXIT

cat > "$REMOTE_SCRIPT" <<SCRIPT
#!/bin/bash
set -euo pipefail
export AWS_REGION=${AWS_REGION}
export ROOT_DOMAIN=${ROOT_DOMAIN}
export CONSOLE_SUB=${CONSOLE_SUB}
export API_SUB=${API_SUB}
export ADMIN_EMAIL=${ADMIN_EMAIL}
aws s3 cp s3://${S3_BUCKET}/scripts/fix-production.sh /tmp/fix.sh --region ${AWS_REGION}
bash /tmp/fix.sh
nginx -t && systemctl reload nginx
certbot --nginx -d ${CONSOLE_SUB}.${ROOT_DOMAIN} -d ${API_SUB}.${ROOT_DOMAIN} --non-interactive --agree-tos -m ${ADMIN_EMAIL} --redirect || true
echo "Done. Console: https://${CONSOLE_SUB}.${ROOT_DOMAIN}  API: https://${API_SUB}.${ROOT_DOMAIN}"
SCRIPT

echo "Uploading fix scripts to S3..."
aws s3 cp scripts/fix-production.sh "s3://${S3_BUCKET}/scripts/fix-production.sh" --region "$AWS_REGION"
aws s3 cp "$REMOTE_SCRIPT" "s3://${S3_BUCKET}/scripts/switch-domain-remote.sh" --region "$AWS_REGION"

echo "Running domain switch on ${INSTANCE_ID}..."
COMMAND_ID="$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 900 \
  --parameters "commands=[\"aws s3 cp s3://${S3_BUCKET}/scripts/switch-domain-remote.sh /tmp/switch-domain-remote.sh --region ${AWS_REGION}\",\"bash /tmp/switch-domain-remote.sh\"]" \
  --region "$AWS_REGION" \
  --query 'Command.CommandId' \
  --output text)"

echo "SSM command: $COMMAND_ID"
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --region "$AWS_REGION"
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' \
  --output text
