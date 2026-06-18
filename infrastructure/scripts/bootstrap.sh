#!/bin/bash
# Fleetbase EC2 bootstrap — runs on first boot via CloudFormation UserData.
# Config is pulled from SSM Parameter Store (written by the CloudFormation stack).

set -euo pipefail

exec > >(tee /var/log/fleetbase-bootstrap.log) 2>&1

PROJECT="${PROJECT}"
ENVIRONMENT="${ENVIRONMENT}"
AWS_REGION="${AWS_REGION}"
SSM_PREFIX="/${PROJECT}/${ENVIRONMENT}"
INSTALL_DIR="/opt/fleetbase"
FLEETBASE_REPO="${FLEETBASE_REPO:-https://github.com/fleetbase/fleetbase.git}"
FLEETBASE_REF="${FLEETBASE_REF:-main}"

echo "==> Fleetbase bootstrap starting"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq nginx certbot python3-certbot-nginx awscli git

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker ubuntu || true

get_param() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text --region "$AWS_REGION"
}

ROOT_DOMAIN="$(get_param "${SSM_PREFIX}/root-domain")"
CONSOLE_SUB="$(get_param "${SSM_PREFIX}/console-subdomain")"
API_SUB="$(get_param "${SSM_PREFIX}/api-subdomain")"
ADMIN_EMAIL="$(get_param "${SSM_PREFIX}/admin-email")"
CONSOLE_HOST="https://${CONSOLE_SUB}.${ROOT_DOMAIN}"
API_HOST="https://${API_SUB}.${ROOT_DOMAIN}"
DB_HOST="$(get_param "${SSM_PREFIX}/db-host")"
DB_SECRET_ARN="$(get_param "${SSM_PREFIX}/db-secret-arn")"
DB_CREDS="$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --query SecretString --output text --region "$AWS_REGION")"
DB_USER="$(echo "$DB_CREDS" | jq -r .username)"
DB_PASS="$(echo "$DB_CREDS" | jq -r .password)"
DB_NAME="$(get_param "${SSM_PREFIX}/db-name")"
REDIS_HOST="$(get_param "${SSM_PREFIX}/redis-host")"
S3_BUCKET="$(get_param "${SSM_PREFIX}/s3-bucket")"
APP_KEY="$(get_param "${SSM_PREFIX}/app-key")"
if [[ "$APP_KEY" == *"CHANGEME"* ]]; then
  APP_KEY="$(docker run --rm fleetbase/fleetbase-api:latest php artisan key:generate --show)"
  aws ssm put-parameter --name "${SSM_PREFIX}/app-key" --type String --value "$APP_KEY" --overwrite --region "$AWS_REGION"
fi

mkdir -p "$INSTALL_DIR"
if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
  git clone --depth 1 --branch "$FLEETBASE_REF" "$FLEETBASE_REPO" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

cat > docker-compose.override.yml <<EOF
services:
  application:
    environment:
      APP_KEY: "${APP_KEY}"
      APP_NAME: "United Logistics"
      APP_URL: "${API_HOST}"
      CONSOLE_HOST: "${CONSOLE_HOST}"
      APP_ENV: "production"
      APP_DEBUG: "false"
      DATABASE_URL: "mysql://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}"
      REDIS_HOST: "${REDIS_HOST}"
      REDIS_URL: "tcp://${REDIS_HOST}:6379"
      CACHE_DRIVER: "redis"
      QUEUE_CONNECTION: "redis"
      SESSION_DRIVER: "redis"
      SESSION_DOMAIN: ".${ROOT_DOMAIN}"
      FILESYSTEM_DRIVER: "s3"
      AWS_BUCKET: "${S3_BUCKET}"
      AWS_DEFAULT_REGION: "${AWS_REGION}"
      BROADCAST_DRIVER: "socketcluster"
      MAIL_FROM_NAME: "United Logistics"
      LOG_CHANNEL: "daily"
      REGISTRY_HOST: "https://registry.fleetbase.io"
      REGISTRY_PREINSTALLED_EXTENSIONS: "true"
      OSRM_HOST: "https://router.project-osrm.org"
    restart: unless-stopped
  queue:
    environment:
      DATABASE_URL: "mysql://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}"
      REDIS_HOST: "${REDIS_HOST}"
      REDIS_URL: "tcp://${REDIS_HOST}:6379"
      CACHE_DRIVER: "redis"
      QUEUE_CONNECTION: "redis"
    restart: unless-stopped
  scheduler:
    environment:
      DATABASE_URL: "mysql://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}"
      REDIS_HOST: "${REDIS_HOST}"
      REDIS_URL: "tcp://${REDIS_HOST}:6379"
      CACHE_DRIVER: "redis"
      QUEUE_CONNECTION: "redis"
    restart: unless-stopped
  socket:
    environment:
      SOCKETCLUSTER_OPTIONS: '{"origins":"${CONSOLE_HOST}:*,${API_HOST}:*,wss://${API_SUB}.${ROOT_DOMAIN}:*,ws://${API_SUB}.${ROOT_DOMAIN}:*"}'
    restart: unless-stopped
  console:
    restart: unless-stopped
  httpd:
    restart: unless-stopped
EOF

mkdir -p console
cat > console/fleetbase.config.json <<EOF
{
  "API_HOST": "${API_HOST}",
  "SOCKETCLUSTER_HOST": "${API_HOST}",
  "SOCKETCLUSTER_PATH": "/socketcluster/",
  "SOCKETCLUSTER_SECURE": "true"
}
EOF

docker compose build console
docker compose pull application queue scheduler socket httpd || true
docker compose up -d application queue scheduler socket console httpd

for i in $(seq 1 30); do
  if docker compose exec -T application php artisan --version >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

docker compose exec -T application bash -c "./deploy.sh" || true

cat > /etc/nginx/sites-available/fleetbase <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${CONSOLE_SUB}.${ROOT_DOMAIN};
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:4200;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name ${API_SUB}.${ROOT_DOMAIN};
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /socketcluster/ {
        proxy_pass http://127.0.0.1:38000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/fleetbase /etc/nginx/sites-enabled/fleetbase
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

if getent hosts "${CONSOLE_SUB}.${ROOT_DOMAIN}" >/dev/null && curl -sf "http://${CONSOLE_SUB}.${ROOT_DOMAIN}" >/dev/null; then
  certbot --nginx \
    -d "${CONSOLE_SUB}.${ROOT_DOMAIN}" \
    -d "${API_SUB}.${ROOT_DOMAIN}" \
    --non-interactive \
    --agree-tos \
    -m "${ADMIN_EMAIL}" || true
fi

echo "==> Fleetbase bootstrap complete"
echo "Console: ${CONSOLE_HOST}"
echo "API: ${API_HOST}"
