#!/bin/bash
set -euo pipefail
cd /opt/fleetbase

AWS_REGION="${AWS_REGION:-us-east-1}"
DB_SECRET_ARN="${DB_SECRET_ARN:-arn:aws:secretsmanager:us-east-1:828885964402:secret:ulogistics/production/database-xMlF2A}"
APP_KEY_SECRET_ARN="${APP_KEY_SECRET_ARN:-arn:aws:secretsmanager:us-east-1:828885964402:secret:ulogistics/production/app-key-xMlF2A}"

ROOT_DOMAIN="${ROOT_DOMAIN:-unitedsoftware.lat}"
CONSOLE_SUB="${CONSOLE_SUB:-fleet}"
API_SUB="${API_SUB:-api}"
DB_HOST="${DB_HOST:-ulogistics-production-mysql.cohwkmkeet27.us-east-1.rds.amazonaws.com}"
DB_NAME="${DB_NAME:-fleetbase}"
REDIS_HOST="${REDIS_HOST:-ulogistics-production-redis.5jnajb.0001.use1.cache.amazonaws.com}"
S3_BUCKET="${S3_BUCKET:-ulogistics-production-uploads-828885964402}"
CONSOLE_HOST="https://${CONSOLE_SUB}.${ROOT_DOMAIN}"
API_HOST="https://${API_SUB}.${ROOT_DOMAIN}"

DB_CREDS="$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --query SecretString --output text --region "$AWS_REGION")"
DB_USER="$(echo "$DB_CREDS" | jq -r .username)"
DB_PASS="$(echo "$DB_CREDS" | jq -r .password)"
DB_PASS_ENC="$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DB_PASS")"

APP_KEY="$(aws secretsmanager get-secret-value --secret-id "$APP_KEY_SECRET_ARN" --query SecretString --output text --region "$AWS_REGION" 2>/dev/null || true)"
if [[ -z "$APP_KEY" || "$APP_KEY" == *"CHANGEME"* ]]; then
  APP_KEY="$(docker run --rm fleetbase/fleetbase-api:latest php artisan key:generate --show)"
  aws secretsmanager put-secret-value --secret-id "$APP_KEY_SECRET_ARN" --secret-string "$APP_KEY" --region "$AWS_REGION"
fi

cat > docker-compose.override.yml <<EOF
services:
  application:
    environment:
      APP_KEY: "${APP_KEY}"
      APP_URL: "${API_HOST}"
      CONSOLE_HOST: "${CONSOLE_HOST}"
      APP_ENV: production
      APP_DEBUG: "false"
      DATABASE_URL: "mysql://${DB_USER}:${DB_PASS_ENC}@${DB_HOST}/${DB_NAME}"
      REDIS_HOST: "${REDIS_HOST}"
      REDIS_URL: "tcp://${REDIS_HOST}:6379"
      CACHE_DRIVER: redis
      QUEUE_CONNECTION: redis
      SESSION_DRIVER: redis
      SESSION_DOMAIN: ".${ROOT_DOMAIN}"
      FILESYSTEM_DRIVER: s3
      AWS_BUCKET: "${S3_BUCKET}"
      AWS_DEFAULT_REGION: "${AWS_REGION}"
      BROADCAST_DRIVER: socketcluster
      MAIL_FROM_NAME: "United Logistics"
      LOG_CHANNEL: daily
      REGISTRY_HOST: "https://registry.fleetbase.io"
      REGISTRY_PREINSTALLED_EXTENSIONS: "true"
      OSRM_HOST: "https://router.project-osrm.org"
    restart: unless-stopped
  queue:
    environment:
      DATABASE_URL: "mysql://${DB_USER}:${DB_PASS_ENC}@${DB_HOST}/${DB_NAME}"
      REDIS_HOST: "${REDIS_HOST}"
      REDIS_URL: "tcp://${REDIS_HOST}:6379"
      CACHE_DRIVER: redis
      QUEUE_CONNECTION: redis
    restart: unless-stopped
  scheduler:
    environment:
      DATABASE_URL: "mysql://${DB_USER}:${DB_PASS_ENC}@${DB_HOST}/${DB_NAME}"
      REDIS_HOST: "${REDIS_HOST}"
      REDIS_URL: "tcp://${REDIS_HOST}:6379"
      CACHE_DRIVER: redis
      QUEUE_CONNECTION: redis
    restart: unless-stopped
  socket:
    environment:
      SOCKETCLUSTER_OPTIONS: '{"origins":"${CONSOLE_HOST}:*,${API_HOST}:*"}'
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
docker compose up -d application queue scheduler socket console httpd
sleep 30
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
nginx -t && systemctl reload nginx
docker compose ps
