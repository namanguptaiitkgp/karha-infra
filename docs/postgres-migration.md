# Phase 4 — Postgres migration playbook

This is the ordered runbook for moving the Karha app from SQLite to RDS Postgres. It assumes Phases 1 and 2 are live and Phase 3 (CDN) is optional but recommended.

## When to do this

Any one of:

- SQLite DB file > 1 GB on disk
- More than ~50 orders / day
- Need to scale to more than one app instance (SQLite can't be shared)
- Want point-in-time recovery beyond the daily S3 tar backup

If none of these apply, **don't migrate** — SQLite is genuinely fine for the launch traffic profile and avoids ~$15/mo of RDS cost after the Free Tier expires.

## What's already in place

- `terraform/phase4-postgres/` — RDS instance, security group, subnet group, master password in Parameter Store, SSL-required connection.
- `scripts/pgloader-migrate.sh` — one-shot data copy with downtime, restart, health check, and rollback instructions.
- `src/lib/env.ts` (in karha-web) — reads `DATABASE_URL` from env. Presence flips the driver from SQLite to Postgres. No code change needed in any feature route — they all go through `getDb()`.

## What needs the code-side change

The audit (in the roadmap plan) found:

- 79 files import `getDb()`. **All use parameterised `.prepare(sql).get/all/run` patterns.** The good news: zero string-concatenated SQL, zero exotic SQLite features.
- 12 transaction call sites use the `db.transaction(()=>...)()` callable pattern.
- 8 migration checks use `PRAGMA table_info()`.

The follow-up PR in `karha-web` does these things:

1. Adds `postgres` (porsager/postgres) to dependencies — chosen over `pg` because the API is cleaner and the bundle is smaller. Keeps `better-sqlite3` for ~30 days as a rollback escape hatch.

2. Splits `src/lib/db.ts` into a router:

```ts
// src/lib/db.ts
import { isPostgres } from "@/lib/env";
import { getSqliteDb } from "./db-sqlite";   // existing logic, renamed
import { getPgDb } from "./db-pg";

export function getDb() {
  return isPostgres() ? getPgDb() : getSqliteDb();
}
```

3. Adds `src/lib/db-pg.ts` exposing the same shape better-sqlite3 has — `prepare(sql)` returning `{ get(), all(), run() }`, plus `transaction(fn)`. The Postgres adapter does two extra things:

   - **Translates `?` placeholders to `$1, $2, …`** before sending to Postgres. The translation is a 5-line function over the SQL text.
   - **Wraps async client calls in a sync-feeling API** using `Atomics.wait` on a worker, OR (cleaner) bumps every call site to `await getDb().prepare(sql).get(...)`. The latter is the *right* answer; option two below is the staged path.

4. **Migrates DDL switches**: in `migrateDb()`, rewrites the 8 `PRAGMA table_info()` calls to `SELECT column_name FROM information_schema.columns WHERE table_name = ?`. Drops the line `db.pragma("journal_mode = WAL")` (it's a no-op on Postgres and would error). Rewrites 6 `INTEGER PRIMARY KEY AUTOINCREMENT` → `BIGSERIAL PRIMARY KEY`. Rewrites one `INSERT OR IGNORE` (in `seed.ts`) → `INSERT … ON CONFLICT DO NOTHING`.

5. **Updates 12 transaction call sites** to use the new `db.transaction(async (q) => …)` API (async because Postgres is async). Each is a 3-line change.

### The async question

The synchronous `getDb().prepare(sql).get(...)` pattern is a SQLite-specific affordance. Postgres clients are inherently async. There are two paths:

**Path A (cleaner, recommended): refactor 79 files to async over 2-3 days.**
- Walk the import graph from `getDb` outward. Most call sites are inside `async function` route handlers that just need `await` added.
- Server components and API routes are already async.
- Change is mechanical: tooling-friendly find-and-replace + tsc to confirm.
- Same code path on SQLite (we make better-sqlite3's sync API pretend to be async by wrapping returns in `Promise.resolve(...)`).

**Path B (faster, debt): use a sync-feeling shim.**
- `pg-native` or a worker-thread-based shim that blocks Node's event loop until Postgres responds.
- Avoids touching call sites but bottlenecks the whole server on every query (the entire point of an async runtime is undone).
- Acceptable as a 2-week stopgap to get on Postgres without a refactor; not acceptable long-term.

**Recommendation**: Path A. Schedule it as a focused 2-3 day sprint; the audit confirms the call sites are uniform and the change is mechanical. The migration script (`pgloader-migrate.sh`) and this playbook are designed assuming Path A is done first.

## Cutover sequence (assumes Path A is merged)

```
Day 0:  terraform apply in phase4-postgres   (instance comes up, ~10 min)
        Master password lands in Parameter Store

Day 1:  Create karha_app role on the DB:
          ssh ec2-user@karha.in
          PGPASSWORD=$(aws ssm get-parameter --name /karha/prod/DB_MASTER_PASSWORD --with-decryption --query Parameter.Value --output text) \
            psql -h <endpoint> -U karha_admin -d karha_prod \
            -f /home/karha/karha-infra/scripts/create-app-role.sql
        Update /karha/prod/DATABASE_URL in Parameter Store with karha_app password

Day 2:  Deploy karha-web with the Path A refactor merged but DATABASE_URL
        unset on the box — it stays on SQLite. Confirm everything still works.
        This is the "no-DB-change" canary deploy: catches any regression
        in the Path A refactor before we add the migration variable.

Day 3:  Schedule a maintenance window (post midnight IST works well).
        Pre-window:
          - Email customers (if any active) about a 15-min downtime.
          - Take a manual SQLite backup as belt-and-braces.
        At T-0:
          - bash /home/karha/karha-infra/scripts/pgloader-migrate.sh
          - 5-15 min later, /api/health confirms db: ok against Postgres.
        Post-window:
          - Smoke-test admin login + a test order.
          - Watch CloudWatch + Sentry for 1-2 hours for any error spikes.

Day 5:  After 48 h of clean operation:
          - Remove `better-sqlite3` from package.json, ship a release.
          - Delete `database/karha.db*` after one more month of safety.
```

## Rollback paths

- **Before pgloader runs**: just unset DATABASE_URL in Parameter Store and `pm2 reload karha --update-env`. The app falls back to SQLite, no data lost.
- **During pgloader**: the SQLite DB is unchanged (pgloader copies, doesn't move). Same rollback as above.
- **After pgloader, before any new orders**: same — unset DATABASE_URL, reload. Postgres has the orders pgloader copied; SQLite has them too. No drift.
- **After pgloader and new orders have landed on Postgres only**: harder. Either:
  - Live with it and forward-fix any Postgres-only bugs.
  - Export the new orders from Postgres back to SQLite via `pg_dump --data-only --table=orders`, manually import — accepts ~5 min more downtime.

## Cost guardrails

Phase 4 adds **$0/mo for 12 months** (Free Tier) and ~**$13-15/mo after** for db.t4g.micro on-demand + 20 GB gp3 + automated backups.

If you want Multi-AZ from day one: roughly **doubles the compute cost** (~$25-28/mo). Recommend keeping single-AZ until Phase 5 actually wants it.

## Verification checklist (post-cutover)

1. `/api/health` → 200 with `db: ok` and `db_driver: postgres`.
2. Admin login at `/admin` succeeds with the same credentials.
3. New customer registration succeeds.
4. Place a test order — appears in `/admin → Orders` within 5 seconds.
5. Razorpay test payment captures correctly (the verify endpoint touches `orders` and `order_status_history` in a transaction — confirms the new transaction wrapper works).
6. CloudWatch RDS metrics show CPU < 30 %, connections < 10 — sane baseline.
7. Sentry shows no spike in errors versus the pre-cutover baseline.
