#!/usr/bin/env bash

set -euo pipefail

# Mevo stack installer (no Docker)
# - Installs Node.js 18, nginx, basic packages
# - Builds and runs: mevo-api (NestJS), mevo-v2 (Vite static), mevobot_v2 (Nuxt 3 SSR)
# - Creates systemd services and Nginx config
#
# Usage examples:
#   sudo ./mevo_install.sh --domain example.com
#   sudo ./mevo_install.sh --domain example.com --user ubuntu --src /var/www/mevo-src
#   sudo ./mevo_install.sh --domain example.com --run-certbot --email admin@example.com

DOMAIN=""
DEPLOY_USER="${SUDO_USER:-${USER}}"
SRC_DIR="$(pwd)"
BASE_DIR="/var/www/mevo"
INSTALL_MONGODB=0
RUN_CERTBOT=0
CERTBOT_EMAIL=""
API_PORT=3000
WIDGET_PORT=3002

function usage() {
  cat <<USAGE
Usage: sudo $0 --domain DOMAIN [--user USER] [--src PATH] [--install-mongodb] [--run-certbot --email EMAIL]

Options:
  --domain DOMAIN          Required. Public domain for Nginx server_name
  --user USER              System user that will run the services (default: $DEPLOY_USER)
  --src PATH               Path containing mevo-api, mevo-v2, mevobot_v2 (default: current dir)
  --install-mongodb        Install mongodb from apt (optional)
  --run-certbot            Obtain Let's Encrypt certificate via certbot (optional)
  --email EMAIL            Email for certbot (used only with --run-certbot)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="$2"; shift 2 ;;
    --user)
      DEPLOY_USER="$2"; shift 2 ;;
    --src)
      SRC_DIR="$2"; shift 2 ;;
    --install-mongodb)
      INSTALL_MONGODB=1; shift 1 ;;
    --run-certbot)
      RUN_CERTBOT=1; shift 1 ;;
    --email)
      CERTBOT_EMAIL="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root (use sudo)." >&2
  exit 1
fi

if [[ -z "$DOMAIN" ]]; then
  echo "--domain is required" >&2
  usage
  exit 1
fi

echo "==> Settings"
echo "Domain:        $DOMAIN"
echo "Deploy user:    $DEPLOY_USER"
echo "Source dir:     $SRC_DIR"
echo "Base dir:       $BASE_DIR"
echo "Install MongoDB:$INSTALL_MONGODB"
echo "Run Certbot:    $RUN_CERTBOT"

echo "==> Updating apt and installing base packages"
apt-get update -y
apt-get install -y curl git rsync nginx ufw build-essential

if [[ "$INSTALL_MONGODB" -eq 1 ]]; then
  echo "==> Installing MongoDB (apt)"
  apt-get install -y mongodb || true
  systemctl enable mongodb || true
  systemctl start mongodb || true
fi

echo "==> Installing Node.js 18 (NodeSource)"
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
node -v
npm -v

echo "==> Preparing target directories"
mkdir -p "$BASE_DIR"
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$BASE_DIR"

for d in mevo-api mevo-v2 mevobot_v2; do
  if [[ ! -d "$SRC_DIR/$d" ]]; then
    echo "Missing directory: $SRC_DIR/$d" >&2
    exit 1
  fi
done

echo "==> Syncing project folders to $BASE_DIR"
rsync -a --delete "$SRC_DIR/mevo-api/" "$BASE_DIR/mevo-api/"
rsync -a --delete "$SRC_DIR/mevo-v2/" "$BASE_DIR/mevo-v2/"
rsync -a --delete "$SRC_DIR/mevobot_v2/" "$BASE_DIR/mevobot_v2/"
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$BASE_DIR"

echo "==> Building mevo-api"
cd "$BASE_DIR/mevo-api"
npm ci
npm run build

if [[ ! -f src/common/envs/production.env ]]; then
  echo "==> Creating production.env from local.env (please update secrets!)"
  if [[ -f src/common/envs/local.env ]]; then
    cp src/common/envs/local.env src/common/envs/production.env
    sed -i 's/^MODE=.*/MODE=production/' src/common/envs/production.env || true
  else
    cat > src/common/envs/production.env <<EOF
MODE=production
MONGODB_URI=
JWT_SECRET=
JWT_EXPIRATION_TIME=86400
PORT=$API_PORT
EOF
  fi
fi

echo "==> Building mevo-v2 (and setting API_ROOT to /api)"
cd "$BASE_DIR/mevo-v2"
if grep -q "^const API_ROOT = \"http://localhost/api\";" src/utils/http/request.ts 2>/dev/null; then
  sed -i 's#^const API_ROOT = \"http://localhost/api\";#const API_ROOT = "/api";#' src/utils/http/request.ts || true
fi
npm ci
npm run build

echo "==> Building mevobot_v2"
cd "$BASE_DIR/mevobot_v2"
npm ci
npm run build

echo "==> Creating systemd services"
cat > /etc/systemd/system/mevo-api.service <<EOF
[Unit]
Description=Mevo API (NestJS)
After=network.target

[Service]
Type=simple
User=$DEPLOY_USER
WorkingDirectory=$BASE_DIR/mevo-api
Environment=NODE_ENV=production
Environment=PORT=$API_PORT
ExecStart=/usr/bin/npm run start:prod --silent
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mevobot-v2.service <<EOF
[Unit]
Description=Mevobot V2 (Nuxt 3)
After=network.target

[Service]
Type=simple
User=$DEPLOY_USER
WorkingDirectory=$BASE_DIR/mevobot_v2
Environment=NODE_ENV=production
Environment=PORT=$WIDGET_PORT
ExecStart=/usr/bin/node .output/server/index.mjs
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mevo-api
systemctl enable mevobot-v2
systemctl restart mevo-api
systemctl restart mevobot-v2

echo "==> Writing Nginx site config for $DOMAIN"
cat > /etc/nginx/sites-available/mevo.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $BASE_DIR/mevo-v2/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:$API_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /widget/ {
        proxy_pass http://127.0.0.1:$WIDGET_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/mevo.conf /etc/nginx/sites-enabled/mevo.conf
nginx -t
systemctl reload nginx

if [[ "$RUN_CERTBOT" -eq 1 ]]; then
  if [[ -z "$CERTBOT_EMAIL" ]]; then
    echo "--run-certbot provided but --email is missing; skipping certbot." >&2
  else
    echo "==> Installing and running certbot"
    apt-get install -y certbot python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n || true
  fi
fi

echo "==> Done"
echo "Frontend:  http://$DOMAIN/"
echo "API:       http://$DOMAIN/api/"
echo "Widget:    http://$DOMAIN/widget/"


