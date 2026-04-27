# karha.in operations runbook

The "how do I…" for the karha.in production deployment. Pair with `postgres-migration.md` for Phase 4 specifics and `secrets.md` for credential rotation.

## Deploy a new release

Normal path (after Phase 2 is set up):

1. Open a PR against `karha-web`'s `main`. CI runs typecheck + lint + build on every PR push.
2. Merge to `main`. The `Deploy to production` GitHub Actions workflow:
   - Builds the standalone artefact
   - SCPs it to `/tmp/release.tar.gz` on the EC2 box
   - Atomically swaps `/home/karha/app` to point at the new release
   - `pm2 reload karha --update-env`
   - Hits `https://karha.in/api/health` until it returns 200 (≤ 60 s)
3. CloudWatch + Sentry confirm no error-rate regression for 5 min.

Manual fallback if the workflow is broken:

```bash
ssh -i ~/.ssh/karha-prod.pem ec2-user@karha.in
sudo -u karha bash <<'CMD'
cd /home/karha/app
git pull origin main
npm ci
npm run build
cp -r public .next/standalone/
cp -r .next/static .next/standalone/.next/
pm2 reload karha --update-env
CMD
```

## Rollback to the previous release

The deploy workflow keeps the last 3 releases on disk under `/home/karha/releases/<sha>/`. Switch back with:

```bash
ssh -i ~/.ssh/karha-prod.pem ec2-user@karha.in
sudo -u karha bash <<'CMD'
ls -1dt /home/karha/releases/*       # pick the previous sha
ln -sfn /home/karha/releases/<previous-sha> /home/karha/app
pm2 reload karha --update-env
CMD
```

Verify with `curl https://karha.in/api/health` and the log.

If the issue is data-side (a bad migration ran), the rollback also requires restoring the most recent S3 backup — see `restore-from-backup.sh` (TODO: add this script when first needed).

## Restart the app

```bash
ssh ec2-user@karha.in
sudo -u karha pm2 restart karha   # cold restart (drops connections)
sudo -u karha pm2 reload karha    # zero-downtime restart (preferred)
```

## See logs

- App stdout/stderr: `sudo -u karha pm2 logs karha --lines 200`
- Nginx access: `sudo tail -f /var/log/nginx/access.log`
- Nginx error: `sudo tail -f /var/log/nginx/error.log`
- CloudWatch (Phase 2+): log groups `karha/app/stdout`, `karha/app/stderr`, `karha/nginx/access`, `karha/nginx/error`. 14-day retention.
- Sentry (Phase 2+): https://sentry.io/organizations/<your-org>/issues/

## Scale vertically

The t3.micro is sufficient for the launch traffic profile. If CPU sustains > 70 % or memory pressure causes swap thrashing:

1. Stop the box: `aws ec2 stop-instances --instance-ids <id>`
2. Change instance type: console → Actions → Instance Settings → Change instance type → t3.small (~$15/mo) or t3.medium (~$30/mo)
3. Start: `aws ec2 start-instances --instance-ids <id>`
4. The Elastic IP and EBS volume re-attach automatically. PM2 starts the app on boot.

Total downtime: ~2 minutes.

## Renew SSL certificate

Certbot installs a daily renewal cron. To force a renewal:

```bash
sudo certbot renew --force-renewal
sudo systemctl reload nginx
```

Dry run before forcing: `sudo certbot renew --dry-run`.

## Restore from backup (DB)

S3 has the last 30 daily tarballs at `s3://karha-prod-backups/daily/`.

```bash
ssh ec2-user@karha.in
sudo -u karha bash <<'CMD'
cd /tmp
aws s3 cp s3://karha-prod-backups/daily/karha-2026-04-15.tar.gz .
tar -xzf karha-2026-04-15.tar.gz
cd /home/karha/app
sudo -u karha pm2 stop karha
mv database/karha.db database/karha.db.before-restore
mv /tmp/karha.db.bak database/karha.db
mv /tmp/uploads/* public/uploads/   # only if you also want to restore uploads
sudo -u karha pm2 reload karha
CMD
```

Phase 4+ uses RDS PITR — different procedure; see `postgres-migration.md`.

## Add an admin user

Sign in to `/admin` as the existing `super_admin` (`admin@karha.in`, `karha2026`), then:

1. **Admin Users** section
2. Add user with role `admin` / `editor` / `viewer`
3. They receive an email with credentials (Phase 2+ once SES is wired; until then, share manually)

## Rotate JWT_SECRET

See `docs/secrets.md`.

## Set up the AWS Budgets alert (manual, one-time)

Terraform doesn't reliably manage Budgets. Console:

1. AWS Cost Management → Budgets → Create budget
2. Cost budget · Monthly · Fixed $50
3. Alert at 80 % actual ($40), 100 % actual ($50), 100 % forecast ($50)
4. SNS topic: `karha-billing-alarms` (created by Phase 1 Terraform)

## Common errors

- **502 Bad Gateway from Nginx** — the Next.js process isn't responding. Check `pm2 status` and `pm2 logs karha`. Restart with `pm2 reload karha`.
- **EACCES on /home/karha/app/database/** — file ownership got mangled. Fix with `sudo chown -R karha:karha /home/karha/app`.
- **Let's Encrypt renewal fails** — usually CloudFront caching the `.well-known/acme-challenge` path (Phase 3 issue). Add a CloudFront behaviour for `/.well-known/acme-challenge/*` that bypasses cache and forwards to the EC2 origin.
- **Razorpay webhook returns 401** — webhook signature mismatch. Confirm the secret in admin → Integrations matches the Razorpay dashboard.
- **Health check 503 with `db: down`** — DB connection broken. SQLite: probably out of disk; check `df -h`. Postgres: check the security group allows EC2 → RDS, and `aws rds describe-db-instances` shows status `available`.
