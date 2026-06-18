#!/bin/bash
# Fleetbase EC2 bootstrap — config via UserData env vars from CloudFormation.

set -euo pipefail

exec > >(tee /var/log/fleetbase-bootstrap.log) 2>&1

PROJECT="${PROJECT:-ulogistics}"
ENVIRONMENT="${ENVIRONMENT:-production}"
AWS_REGION="${AWS_REGION:-us-east-1}"
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

ROOT_DOMAIN="${ROOT_DOMAIN:?ROOT_DOMAIN required}"
CONSOLE_SUB="${CONSOLE_SUB:?CONSOLE_SUB required}"
API_SUB="${API_SUB:?API_SUB required}"
ADMIN_EMAIL="${ADMIN_EMAIL:?ADMIN_EMAIL required}"
DB_HOST="${DB_HOST:?DB_HOST required}"
DB_NAME="${DB_NAME:-fleetbase}"
DB_SECRET_ARN="${DB_SECRET_ARN:?DB_SECRET_ARN required}"
REDIS_HOST="${REDIS_HOST:?REDIS_HOST required}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET required}"

CONSOLE_HOST="https://${CONSOLE_SUB}.${ROOT_DOMAIN}"
API_HOST="https://${API_SUB}.${ROOT_DOMAIN}"

DB_CREDS="$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --query SecretString --output text --region "$AWS_REGION")"
DB_USER="$(echo "$DB_CREDS" | jq -r .username)"
DB_PASS="$(echo "$DB_CREDS" | jq -r .password)"
DB_PASS_ENC="$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PASS")"

APP_KEY=""
if [[ -n "${APP_KEY_SECRET_ARN:-}" ]]; then
  APP_KEY="$(aws secretsmanager get-secret-value --secret-id "$APP_KEY_SECRET_ARN" --query SecretString --output text --region "$AWS_REGION" || true)"
fi
if [[ -z "$APP_KEY" || "$APP_KEY" == *"CHANGEME"* ]]; then
  APP_KEY="$(docker run --rm fleetbase/fleetbase-api:latest php artisan key:generate --show)"
  if [[ -n "${APP_KEY_SECRET_ARN:-}" ]]; then
    aws secretsmanager put-secret-value --secret-id "$APP_KEY_SECRET_ARN" --secret-string "$APP_KEY" --region "$AWS_REGION"
  fi
fi

mkdir -p "$INSTALL_DIR"
if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
  git clone --depth 1 --branch "$FLEETBASE_REF" "$FLEETBASE_REPO" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

cat > docker-compose.override.yml <<EOF
services:
  database:
    profiles: ["disabled"]
  cache:
    profiles: ["disabled"]
  application:
    environment:
      APP_KEY: "${APP_KEY}"
      APP_NAME: "United Logistics"
      APP_URL: "${API_HOST}"
      CONSOLE_HOST: "${CONSOLE_HOST}"
      APP_ENV: "production"
      APP_DEBUG: "false"
      DATABASE_URL: "mysql://${DB_USER}:${DB_PASS_ENC}@${DB_HOST}/${DB_NAME}"
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
      DATABASE_URL: "mysql://${DB_USER}:${DB_PASS_ENC}@${DB_HOST}/${DB_NAME}"
      REDIS_HOST: "${REDIS_HOST}"
      REDIS_URL: "tcp://${REDIS_HOST}:6379"
      CACHE_DRIVER: "redis"
      QUEUE_CONNECTION: "redis"
    restart: unless-stopped
  scheduler:
    environment:
      DATABASE_URL: "mysql://${DB_USER}:${DB_PASS_ENC}@${DB_HOST}/${DB_NAME}"
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

echo "==> Fleetbase bootstrap complete"
echo "Console: ${CONSOLE_HOST}"
echo "API: ${API_HOST}"
echo "Point DNS A records for ${CONSOLE_SUB} and ${API_SUB} to this server's public IP"
