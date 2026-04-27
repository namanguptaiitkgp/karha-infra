#!/bin/bash
#
# pgloader-migrate.sh — one-time SQLite → Postgres data migration.
#
# Run this from the EC2 box AFTER:
#   1. Phase 4 Terraform has provisioned the RDS instance.
#   2. The karha_app role has been created (see Phase 4 next_steps).
#   3. /karha/prod/DATABASE_URL in Parameter Store has been updated
#      with the karha_app password.
#
# What this does:
#   1. Stops the app (PM2) so the SQLite DB stops accepting writes.
#   2. Takes a final SQLite consistency snapshot.
#   3. Runs pgloader to copy every table from SQLite to Postgres,
#      coercing types automatically (TEXT → TEXT, INTEGER → BIGINT,
#      AUTOINCREMENT primary keys → BIGSERIAL).
#   4. Patches a few SQLite-isms that don't translate cleanly.
#   5. Sets the SQLite DB to read-only as belt-and-braces.
#   6. Restarts the app — at this point lib/env.ts sees DATABASE_URL
#      and getDb() returns the Postgres adapter (per docs/postgres-
#      migration.md).
#   7. Hits /api/health to confirm.
#
# DOWNTIME: typically 5-15 minutes for a < 1 GB SQLite database.
# Schedule during your lowest-traffic window (02:00 IST is good).
#
# ROLLBACK: if anything goes wrong before step 6, just re-start PM2
# (the SQLite DB is unchanged — pgloader copies, doesn't move). If
# you've already restarted the app on Postgres and orders have been
# written, you'll need to backfill those into SQLite manually before
# rolling back. Test on a staging copy first if at all possible.

set -euo pipefail

APP_DIR="/home/karha/app"
SQLITE_DB="${APP_DIR}/database/karha.db"
APP_USER="karha"

if ! command -v pgloader >/dev/null 2>&1; then
    echo "Installing pgloader…"
    sudo dnf install -y pgloader || {
        echo "pgloader not available via dnf. Install with:"
        echo "  sudo dnf install -y postgresql16 sbcl"
        echo "  curl -L https://github.com/dimitri/pgloader/releases/download/v3.6.10/pgloader.tar.gz | tar xz"
        exit 1
    }
fi

DATABASE_URL=$(aws ssm get-parameter --name /karha/prod/DATABASE_URL --with-decryption --query Parameter.Value --output text)
if [[ -z "$DATABASE_URL" ]]; then
    echo "DATABASE_URL not set in Parameter Store. Did Phase 4 Terraform run?"
    exit 1
fi

echo "── 1. Stopping app to freeze SQLite ────────────────────"
sudo -u "$APP_USER" pm2 stop karha

echo "── 2. Taking final SQLite snapshot ─────────────────────"
SNAPSHOT="${APP_DIR}/database/karha.db.pre-pg-migration.$(date +%Y%m%d-%H%M%S)"
sqlite3 "$SQLITE_DB" ".backup $SNAPSHOT"
echo "    snapshot: $SNAPSHOT"

echo "── 3. Running pgloader ─────────────────────────────────"
# pgloader needs the URL in its own format. Convert.
PG_URL_PGLOADER=$(echo "$DATABASE_URL" | sed 's|postgresql://|postgres://|; s|?sslmode=require||')

cat > /tmp/pgloader.load <<LOAD
LOAD DATABASE
     FROM   sqlite://${SQLITE_DB}
     INTO   ${PG_URL_PGLOADER}

  WITH include drop, create tables, create indexes, reset sequences,
       data only is false,
       workers = 4

   SET work_mem to '64MB',
       maintenance_work_mem to '256 MB'

CAST type integer to bigint,
     type tinyint to smallint,
     type real to double precision,
     type datetime to timestamptz drop typemod,

ALTER SCHEMA 'main' RENAME TO 'public'

;
LOAD

pgloader /tmp/pgloader.load
rm /tmp/pgloader.load

echo "── 4. Post-load fixups ────────────────────────────────"
# Ensure sequences match the largest existing id (pgloader usually
# does this with `reset sequences` but belt-and-braces).
psql "$DATABASE_URL" <<SQL
DO \$\$
DECLARE
    r RECORD;
    seq_name TEXT;
    max_val BIGINT;
BEGIN
    FOR r IN SELECT table_name, column_name FROM information_schema.columns
             WHERE column_default LIKE 'nextval%' AND table_schema = 'public'
    LOOP
        seq_name := substring(r.column_default FROM 'nextval\(''([^'']+)''');
        EXECUTE format('SELECT COALESCE(MAX(%I), 0) FROM %I', r.column_name, r.table_name) INTO max_val;
        IF max_val > 0 THEN
            EXECUTE format('SELECT setval(%L, %s)', seq_name, max_val);
        END IF;
    END LOOP;
END \$\$;

-- Sanity check: row counts per table
SELECT schemaname, relname, n_live_tup AS rows
  FROM pg_stat_user_tables
  WHERE schemaname = 'public'
  ORDER BY n_live_tup DESC;
SQL

echo "── 5. Marking SQLite DB read-only ─────────────────────"
chmod 444 "$SQLITE_DB" || true
chmod 444 "${SQLITE_DB}-wal" 2>/dev/null || true
chmod 444 "${SQLITE_DB}-shm" 2>/dev/null || true

echo "── 6. Restarting app on Postgres ──────────────────────"
sudo -u "$APP_USER" pm2 reload karha --update-env

echo "── 7. Health check ────────────────────────────────────"
sleep 3
if curl -fsS https://karha.in/api/health | grep -q '"db":"ok"'; then
    echo
    echo "✓ Migration complete. App is now running on Postgres."
    echo "  SQLite snapshot kept at: $SNAPSHOT"
    echo "  Original DB (read-only): $SQLITE_DB"
    echo
    echo "Run smoke tests now:"
    echo "  - Admin login at /admin"
    echo "  - Place a test order at /shop"
    echo "  - Check /admin → Orders that the test order appears"
else
    echo
    echo "✗ Health check failed. Inspect:"
    echo "  pm2 logs karha"
    echo "  curl -v https://karha.in/api/health"
    echo
    echo "If unrecoverable, rollback:"
    echo "  chmod 644 $SQLITE_DB ${SQLITE_DB}-wal ${SQLITE_DB}-shm"
    echo "  aws ssm put-parameter --name /karha/prod/DATABASE_URL --value '' --type SecureString --overwrite"
    echo "  pm2 reload karha --update-env"
    exit 1
fi
