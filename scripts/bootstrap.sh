#!/bin/bash
#
# bootstrap.sh — run ONCE on a fresh EC2 box after `terraform apply`.
#
# Usage (as ec2-user via sudo):
#   curl -O https://raw.githubusercontent.com/namanguptaiitkgp/karha-infra/main/scripts/bootstrap.sh
#   sudo bash bootstrap.sh you@example.com
#
# What this does:
#   1. Installs Node 20 LTS, build tools (better-sqlite3 has native deps),
#      Nginx, certbot, awscli v2, and PM2.
#   2. Adds 2 GB of swap so `next build` doesn't OOM on t3.micro (1 GB RAM).
#   3. Creates a `karha` system user that owns the app + secrets.
#   4. Clones karha-web into /home/karha/app, runs the first build.
#   5. Pulls JWT_SECRET / CRON_SECRET from Parameter Store into a
#      mode-600 .env.production file owned by `karha`.
#   6. Wires up Nginx → 127.0.0.1:3000 with the standalone server.
#   7. Provisions a Let's Encrypt cert for karha.in + www.karha.in.
#   8. Installs the daily S3-backup cron (scripts/backup-to-s3.sh).
#   9. Starts PM2 + persists across reboots.
#
# Idempotent — running it twice just re-applies each step.
#
# After this completes you can deploy new releases via `scripts/deploy.sh`
# (called by the GitHub Actions workflow in Phase 2) or, in a pinch,
# manually with `git pull && npm run build && pm2 reload karha`.

set -euo pipefail

LETSENCRYPT_EMAIL="${1:-}"
if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
  echo "Usage: sudo bash bootstrap.sh <admin-email>"
  exit 1
fi

DOMAIN_PRIMARY="karha.in"
DOMAIN_WWW="www.karha.in"
APP_USER="karha"
APP_DIR="/home/${APP_USER}/app"
GIT_REPO="git@github.com:namanguptaiitkgp/Karha.git"
INFRA_REPO="https://github.com/namanguptaiitkgp/karha-infra.git"
NODE_MAJOR=20

echo "── 1/9 Installing system packages ─────────────────────"
dnf update -y
dnf install -y git make gcc-c++ python3 nginx jq tar gzip
# awscli v2 ships in AL2023; verify
aws --version

echo "── 2/9 Configuring 2 GB swap ──────────────────────────"
if [[ ! -f /swapfile ]]; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q "/swapfile" /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
fi

echo "── 3/9 Installing Node ${NODE_MAJOR} LTS + PM2 ────────"
curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
dnf install -y nodejs
npm install -g pm2

echo "── 4/9 Creating ${APP_USER} system user ───────────────"
if ! id "${APP_USER}" &>/dev/null; then
  useradd -m -s /bin/bash "${APP_USER}"
fi

echo "── 5/9 Cloning karha-web (skip if already present) ────"
if [[ ! -d "${APP_DIR}/.git" ]]; then
  sudo -u "${APP_USER}" git clone "${GIT_REPO}" "${APP_DIR}"
fi
sudo -u "${APP_USER}" git -C "${APP_DIR}" pull

# Persistent data dirs that survive `git pull`
sudo -u "${APP_USER}" mkdir -p "${APP_DIR}/database" "${APP_DIR}/public/uploads"

echo "── 6/9 Building the app (uses standalone output) ──────"
sudo -u "${APP_USER}" bash -c "cd ${APP_DIR} && npm ci && npm run build"

# Standalone output puts server.js at .next/standalone/server.js, but
# expects public/ and .next/static/ to live next to it. Mirror them.
sudo -u "${APP_USER}" bash -c "cd ${APP_DIR} && cp -r public .next/standalone/ && cp -r .next/static .next/standalone/.next/"

echo "── 7/9 Loading secrets from Parameter Store ───────────"
# Pull JWT_SECRET + CRON_SECRET from Parameter Store. The instance
# profile created by Terraform grants us ssm:GetParametersByPath.
sudo -u "${APP_USER}" bash -c "cat > ${APP_DIR}/.env.production" <<EOF
NODE_ENV=production
PORT=3000
NEXT_PUBLIC_SITE_URL=https://${DOMAIN_PRIMARY}
JWT_SECRET=$(aws ssm get-parameter --name /karha/prod/JWT_SECRET --with-decryption --query Parameter.Value --output text)
CRON_SECRET=$(aws ssm get-parameter --name /karha/prod/CRON_SECRET --with-decryption --query Parameter.Value --output text)
EOF
chmod 600 "${APP_DIR}/.env.production"
chown "${APP_USER}:${APP_USER}" "${APP_DIR}/.env.production"

echo "── 8/9 Configuring Nginx + Let's Encrypt ──────────────"
cat > /etc/nginx/conf.d/karha.conf <<'NGINX'
server {
    listen 80;
    server_name karha.in www.karha.in;

    # Admin image uploads — adjust if you allow larger files in future.
    client_max_body_size 25M;

    # Hand the whole site off to Next.js. CloudFront will sit in front
    # of this in Phase 3; until then the HTTPS layer is certbot-managed.
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Basic rate limit on auth + checkout — defends against credential
    # stuffing and pre-payment scrapers on a single box. CloudFront WAF
    # rules in Phase 3 are the production-grade story.
    location ~ ^/api/auth/customer/(login|register) {
        limit_req zone=auth_zone burst=5 nodelay;
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
    }
}
NGINX

# Connection limits — keep simple. Adjust upward if traffic grows.
cat > /etc/nginx/conf.d/zz-rate-limits.conf <<'RL'
limit_req_zone $binary_remote_addr zone=auth_zone:10m rate=10r/m;
RL

systemctl enable --now nginx
nginx -t && systemctl reload nginx

# Install certbot via the Amazon Linux 2023 amazon-linux-extras path.
dnf install -y python3-pip
pip3 install --user certbot certbot-nginx
ln -sfn "$(pwd)/.local/bin/certbot" /usr/local/bin/certbot 2>/dev/null || true
# AL2023 carries certbot via dnf in the latest release; prefer that:
dnf install -y certbot python3-certbot-nginx || true

# Only attempt cert issuance if DNS already points here — otherwise
# the operator runs `certbot --nginx -d karha.in -d www.karha.in` later.
if dig +short "${DOMAIN_PRIMARY}" @8.8.8.8 | grep -q "$(curl -s ifconfig.me)"; then
  certbot --nginx \
    -d "${DOMAIN_PRIMARY}" -d "${DOMAIN_WWW}" \
    --redirect --agree-tos --non-interactive \
    -m "${LETSENCRYPT_EMAIL}"
else
  echo "DNS not pointed at this box yet — skip certbot; rerun manually after A records propagate."
fi

echo "── 9/9 Starting PM2 + setting up backup cron ──────────"
sudo -u "${APP_USER}" bash <<'PM2'
cd /home/karha/app
pm2 start .next/standalone/server.js --name karha --update-env
pm2 save
PM2

# pm2 startup needs root, but the saved process list belongs to karha
env PATH="$PATH:/usr/bin" pm2 startup systemd -u "${APP_USER}" --hp "/home/${APP_USER}"
systemctl enable pm2-${APP_USER}

# Daily S3 backup at 02:00 IST. The script is in version control with
# the rest of the infra repo so we can iterate on it without re-running
# bootstrap.sh.
sudo -u "${APP_USER}" bash -c "[[ -d /home/${APP_USER}/karha-infra ]] || git clone ${INFRA_REPO} /home/${APP_USER}/karha-infra"
cp "/home/${APP_USER}/karha-infra/scripts/backup-to-s3.sh" /home/${APP_USER}/backup-to-s3.sh
chmod +x /home/${APP_USER}/backup-to-s3.sh
chown ${APP_USER}:${APP_USER} /home/${APP_USER}/backup-to-s3.sh
cat > /etc/cron.d/karha-backup <<CRON
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 2 * * * ${APP_USER} /home/${APP_USER}/backup-to-s3.sh >> /var/log/karha-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/karha-backup

echo
echo "✓ Bootstrap complete."
echo
echo "Next steps:"
echo "  - curl -I https://${DOMAIN_PRIMARY} should return 200"
echo "  - Sign in to /admin with admin@karha.in / karha2026 (CHANGE THIS PASSWORD)"
echo "  - sudo certbot renew --dry-run  (confirm autorenew works)"
echo "  - tail -f /var/log/karha-backup.log overnight to see the first backup"
