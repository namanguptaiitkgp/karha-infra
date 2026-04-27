# karha-infra

Deployment infrastructure for [karha-web](https://github.com/namanguptaiitkgp/Karha) — a sibling repo so app code and infrastructure have separate lifecycles.

This folder implements **phases 1 through 4** of the long-term roadmap (`/Users/namangupta/.claude/plans/velvet-hatching-sonnet.md`):

| Phase | Status | What |
|-------|--------|------|
| 0 — Code hardening | In `karha-web` repo | `output: "standalone"`, upload abstraction, env loader, `/api/health` |
| 1 — Day‑1 launch | This repo · `terraform/phase1-launch/` | EC2 t3.micro, EBS, EIP, S3 backups, Nginx, Let's Encrypt |
| 2 — CI/CD + observability | This repo · `github-workflows/`, `terraform/phase2-observability/` | GitHub Actions deploy, CloudWatch logs, Sentry, uptime |
| 3 — S3 uploads + CloudFront | This repo · `terraform/phase3-cdn/` | S3 upload bucket, CloudFront distribution with two origins |
| 4 — RDS Postgres | This repo · `terraform/phase4-postgres/` | RDS db.t4g.micro, DB driver swap, pgloader migration |
| 5 — Containers + autoscaling | Out of scope for now | ECS Fargate, ALB, autoscaling |

## Layout

```
karha-infra/
├── README.md                       (this file)
├── docs/
│   ├── runbook.md                  (oncall: how to deploy, rollback, scale)
│   ├── secrets.md                  (rotation procedures)
│   └── postgres-migration.md       (Phase 4 cutover playbook)
├── terraform/
│   ├── modules/                    (reusable: ec2, s3-uploads, cloudfront, rds, iam)
│   ├── phase1-launch/              (single-box launch)
│   ├── phase2-observability/       (CloudWatch, billing alarm)
│   ├── phase3-cdn/                 (S3 + CloudFront)
│   └── phase4-postgres/            (RDS Postgres)
├── scripts/
│   ├── bootstrap.sh                (run once on a fresh EC2 box)
│   ├── deploy.sh                   (called by GitHub Actions)
│   ├── backup-to-s3.sh             (cron daily)
│   ├── load-secrets.sh             (Parameter Store → .env at boot)
│   └── pgloader-migrate.sh         (Phase 4 one-time DB migration)
└── github-workflows/
    └── deploy.yml                  (copy to `karha-web/.github/workflows/`)
```

## Prerequisites

- AWS account with admin access (for Terraform `apply`).
- AWS CLI configured locally (`aws configure` with an IAM user that has at minimum `ec2:*`, `iam:*`, `s3:*`, `rds:*`, `cloudfront:*`, `ssm:*`, `cloudwatch:*`, `acm:*`).
- Terraform ≥ 1.7 (`brew install terraform`).
- An SSH keypair you control, named `karha-prod` in EC2 → Key Pairs (Terraform will reference the name).
- The `karha.in` domain at GoDaddy (DNS records edited manually after `terraform apply` — see `docs/runbook.md`).

## Bootstrap order (do this once)

```bash
# Phase 1: provision the box + S3 backups + IAM
cd terraform/phase1-launch
terraform init
terraform apply
# Copy the elastic_ip output, set GoDaddy A records for @ and www.
# Wait for DNS to propagate (`dig karha.in @8.8.8.8`).

# Phase 1: bootstrap the EC2 box
ssh -i ~/.ssh/karha-prod.pem ec2-user@<elastic-ip>
curl -O https://raw.githubusercontent.com/namanguptaiitkgp/karha-infra/main/scripts/bootstrap.sh
sudo bash bootstrap.sh   # installs Node, PM2, Nginx, certbot, clones the app, starts PM2

# Phase 2: GitHub Actions
# Copy github-workflows/deploy.yml into karha-web/.github/workflows/
# Add EC2_DEPLOY_KEY (private SSH key) to karha-web's GitHub Secrets.

# Phase 3 (later): S3 + CloudFront
cd ../phase3-cdn && terraform apply
# Set STORAGE_BACKEND=s3, S3_BUCKET=<output> in karha-web's Parameter Store.

# Phase 4 (later): Postgres
cd ../phase4-postgres && terraform apply
# Run scripts/pgloader-migrate.sh from inside the EC2 box.
# Set DATABASE_URL in Parameter Store, redeploy.
```

Each phase is independent — you can stop after Phase 1 and the site is live. Phases 2–4 are progressive improvements with clear triggers documented in the roadmap plan.

## Cost guardrails

`terraform/phase1-launch/main.tf` provisions a CloudWatch billing alarm at $10/mo. AWS Budgets alert at $50 lifetime credit usage is documented in `docs/runbook.md` (manual setup — Budgets isn't well-supported in Terraform yet).
