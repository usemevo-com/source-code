# Mevo is Public Now

You can now host Mevo on your own server without any limitations or restrictions.

[Mevo Github Repository](https://github.com/usemevo-com/source-code)

## Mevo Stack Manual Setup on Ubuntu (no Docker)

This guide walks you through running the following projects on an Ubuntu server without Docker:

- `mevo-api` (NestJS + MongoDB)
- `mevo-v2` (Vue 3 + Vite, built to static files)
- `mevobot_v2` (Nuxt 3 SSR)

It also includes a production Nginx configuration and local development notes.

### Quick automated setup (optional)

If you prefer one-shot installation, use the provided installer script:

```bash
chmod +x ./mevo_install.sh
sudo ./mevo_install.sh --domain example.com
```

Advanced examples:

```bash
# Specify deploy user and a custom source directory containing the three folders
sudo ./mevo_install.sh --domain example.com --user ubuntu --src /var/www/mevo-src

# Also obtain HTTPS with Certbot
sudo ./mevo_install.sh --domain example.com --run-certbot --email admin@example.com
```

### 0) Server prerequisites

Run everything as a non-root user with sudo privileges.

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential git curl nginx ufw

# Firewall (adjust if needed)
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw --force enable
```

Install Node.js 18 LTS with nvm (recommended for all three projects):

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.nvm/nvm.sh
nvm install 18
nvm alias default 18
node -v
npm -v
```

Optional: Install MongoDB locally (or use a managed MongoDB URI). If you already have a remote `MONGODB_URI`, you can skip installing MongoDB on the server.

```bash
# Ubuntu 22.04 example (check MongoDB docs for your distro)
sudo apt-get install -y mongodb
sudo systemctl enable mongodb
sudo systemctl start mongodb
```

### 1) Directory layout on the server

Assume you uploaded the repository (or the three folders) to, e.g., `/var/www/mevo`:

```
/var/www/mevo/
  mevo-api/
  mevo-v2/
  mevobot_v2/
```

Make sure the user that will run the apps owns these folders:

```bash
sudo mkdir -p /var/www/mevo
sudo chown -R $USER:$USER /var/www/mevo
```

### 2) mevo-api (NestJS) – Production setup

Dependencies and build:

```bash
cd /var/www/mevo/mevo-api
npm ci
npm run build
```

Environment configuration:

The API reads env from `src/common/envs/<NODE_ENV>.env`. For production, set `NODE_ENV=production` and ensure `src/common/envs/production.env` contains the correct values (do not commit secrets).

Minimal required keys to review (examples only):

- `MONGODB_URI` – your MongoDB connection string
- `JWT_SECRET`, `JWT_EXPIRATION_TIME`
- `PORT` – default 3000
- Any external service keys you use (Stripe, OpenAI, S3/Spaces, etc.)

```bash
# Example: copy local.env as a starting point and edit
cp src/common/envs/local.env src/common/envs/production.env
sed -i 's/^MODE=.*/MODE=production/' src/common/envs/production.env
# Edit production.env and set real secrets and endpoints
nano src/common/envs/production.env
```

Systemd service for mevo-api (runs on port 3000 by default):

```bash
sudo tee /etc/systemd/system/mevo-api.service > /dev/null <<'EOF'
[Unit]
Description=Mevo API (NestJS)
After=network.target

[Service]
Type=simple
User=%i
WorkingDirectory=/var/www/mevo/mevo-api
Environment=NODE_ENV=production
ExecStart=/bin/bash -lc 'source ~/.nvm/nvm.sh && nvm use 18 && npm run start:prod'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Replace `%i` with your username or edit `User=` accordingly (e.g., `User=ubuntu`). Then enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable mevo-api
sudo systemctl start mevo-api
sudo systemctl status mevo-api --no-pager
```

### 3) mevo-v2 (Vue + Vite) – Build static and serve via Nginx

Important: The frontend currently uses a hardcoded API root in `mevo-v2/src/utils/http/request.ts`:

```ts
const API_ROOT = "http://localhost/api";
```

For production, change it to a relative path so it works behind Nginx on your domain:

```ts
const API_ROOT = "/api";
```

Build the app:

```bash
cd /var/www/mevo/mevo-v2
npm ci
npm run build
```

This produces `dist/`. We’ll point Nginx root to this folder.

### 4) mevobot_v2 (Nuxt 3 SSR) – Build and run as a Node process

Build:

```bash
cd /var/www/mevo/mevobot_v2
npm ci
npm run build
```

Run the built server (Nitro Node server) using systemd on port 3002:

```bash
sudo tee /etc/systemd/system/mevobot-v2.service > /dev/null <<'EOF'
[Unit]
Description=Mevobot V2 (Nuxt 3)
After=network.target

[Service]
Type=simple
User=%i
WorkingDirectory=/var/www/mevo/mevobot_v2
Environment=NODE_ENV=production
Environment=PORT=3002
ExecStart=/bin/bash -lc 'source ~/.nvm/nvm.sh && nvm use 18 && node .output/server/index.mjs'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable mevobot-v2
sudo systemctl start mevobot-v2
sudo systemctl status mevobot-v2 --no-pager
```

### 5) Nginx configuration (single domain)

Assume your domain is `example.com`. We’ll serve:

- `mevo-v2` at `/` (static files)
- `mevo-api` proxied at `/api/` → `http://127.0.0.1:3000/`
- `mevobot_v2` proxied at `/widget/` → `http://127.0.0.1:3002/`

Create a server block:

```bash
sudo tee /etc/nginx/sites-available/mevo.conf > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name example.com;

    # mevo-v2 static frontend
    root /var/www/mevo/mevo-v2/dist;
    index index.html;

    # Vite SPA history fallback
    location / {
        try_files $uri $uri/ /index.html;
    }

    # mevo-api proxy
    location /api/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # mevobot_v2 (Nuxt 3 SSR) proxy under /widget
    location /widget/ {
        proxy_pass http://127.0.0.1:3002/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/mevo.conf /etc/nginx/sites-enabled/mevo.conf
sudo nginx -t && sudo systemctl reload nginx
```

HTTPS: obtain a certificate with Certbot (optional but recommended):

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d example.com
```

### 6) Health checks

- API: `curl -I http://example.com/api` (or a known endpoint)
- Frontend: Visit `http://example.com/`
- Nuxt widget: Visit `http://example.com/widget/`

If you see the frontend but API fails, double-check:

- `mevo-api` service is running (`systemctl status mevo-api`)
- Nginx `/api/` proxy configuration
- CORS (if you later expose API on a different domain; using `/api` under the same domain avoids CORS)

### 7) Local development (optional)

Prerequisites: Node 18, MongoDB (local or remote connection URI).

- mevo-api:
  ```bash
  cd mevo-api
  npm i
  npm run start:local   # loads src/common/envs/local.env
  ```

- mevo-v2:
  ```bash
  cd mevo-v2
  # For local dev, API root is set to http://localhost/api in code
  npm i
  npm run dev
  # Dev server defaults to http://localhost:5173 or 5174 (Vite)
  # Ensure you proxy /api in a local reverse proxy, or run the API on http://localhost:3000 and adjust API_ROOT
  ```

- mevobot_v2:
  ```bash
  cd mevobot_v2
  npm i
  npm run dev -- -p 3002 --host
  # Visit http://localhost:3002
  ```

### 8) Common pitfalls

- Update `mevo-v2/src/utils/http/request.ts` to use `API_ROOT = "/api"` before building for production so the browser calls the same domain.
- Ensure `NODE_ENV=production` for systemd services so `mevo-api` loads `src/common/envs/production.env`.
- If you use a managed MongoDB (recommended), open the IP of your server in the DB network rules and set the correct `MONGODB_URI`.
- For Nuxt SSR, ensure port 3002 is not blocked by firewall (Nginx proxies internally, so external access comes via port 80/443 only).

---

That’s it. After completing the steps, your stack should be reachable at:

- Frontend (mevo-v2): `http(s)://example.com/`
- API (mevo-api): `http(s)://example.com/api/...`
- Widget/App (mevobot_v2): `http(s)://example.com/widget/...`


