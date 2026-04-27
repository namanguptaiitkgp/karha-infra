#!/bin/bash
#
# load-secrets.sh — pull production secrets from Parameter Store into
# /home/karha/app/.env.production. Run once during bootstrap and again
# whenever a secret rotates.
#
# This avoids writing secrets to the EBS volume permanently — a `pm2
# reload --update-env` after this script picks up new values without
# leaving them in shell history or in long-lived files we forget about.

set -euo pipefail

APP_USER="karha"
APP_DIR="/home/${APP_USER}/app"
ENV_FILE="${APP_DIR}/.env.production"
TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT

# Pull every key under /karha/prod/ as a single batch.
aws ssm get-parameters-by-path \
    --path /karha/prod/ \
    --with-decryption \
    --query 'Parameters[*].[Name,Value]' \
    --output text | while IFS=$'\t' read -r name value; do
    # /karha/prod/JWT_SECRET → JWT_SECRET
    short="${name##*/}"
    # Escape any single quotes in values for shell-safe export.
    escaped="${value//\'/\'\\\'\'}"
    echo "${short}='${escaped}'"
done > "$TMP_ENV"

# Add the static values that don't live in Parameter Store.
cat >> "$TMP_ENV" <<EOF
NODE_ENV=production
PORT=3000
NEXT_PUBLIC_SITE_URL=https://karha.in
EOF

# Atomic install — readable only by the app user, then mv'd into
# place. Avoids a partial-file race during reload.
chmod 600 "$TMP_ENV"
chown "${APP_USER}:${APP_USER}" "$TMP_ENV"
mv "$TMP_ENV" "$ENV_FILE"

echo "Wrote $(wc -l <"$ENV_FILE") lines to $ENV_FILE"
