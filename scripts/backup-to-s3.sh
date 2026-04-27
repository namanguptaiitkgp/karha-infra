#!/bin/bash
#
# backup-to-s3.sh — daily backup of the SQLite DB + uploads to S3.
#
# Wired up as /etc/cron.d/karha-backup (02:00 IST daily) by
# bootstrap.sh. The S3 bucket has a 30-day lifecycle rule applied
# by Terraform so old backups expire automatically — this script
# does NOT clean up after itself.
#
# When Phase 4 lands and we move to RDS Postgres, this script
# becomes "back up uploads only" because RDS handles its own
# point-in-time recovery + automated snapshots.

set -euo pipefail

APP_DIR="/home/karha/app"
BUCKET="karha-prod-backups"
DATE=$(date +%Y-%m-%d)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$APP_DIR"

# Online backup of SQLite via the .backup command — produces a
# consistent snapshot without locking the running server. (Plain
# `cp` of karha.db while the server runs would race the WAL.)
if [[ -f database/karha.db ]]; then
    sqlite3 database/karha.db ".backup ${TMPDIR}/karha.db.bak"
else
    echo "WARN: database/karha.db missing — skipping DB backup"
fi

# Tar DB backup + uploads. Compress with gzip — tiny CPU hit, big
# size win for SQLite (lots of repeated column names compress 5-8x).
tar -czf "${TMPDIR}/karha-${DATE}.tar.gz" \
    -C "$TMPDIR" karha.db.bak \
    -C "$APP_DIR" public/uploads

# Use the IAM instance role (no AWS keys on disk) — the policy
# attached by Terraform allows PutObject on this bucket.
aws s3 cp "${TMPDIR}/karha-${DATE}.tar.gz" "s3://${BUCKET}/daily/karha-${DATE}.tar.gz" \
    --no-progress

echo "$(date -Is)  Uploaded daily backup: $(du -h ${TMPDIR}/karha-${DATE}.tar.gz | cut -f1)"
