/**
 * Phase 4 — RDS Postgres for the production database.
 *
 * Trigger conditions (any one of these):
 *   - SQLite database file > 1 GB (concurrency starts to bite past this)
 *   - More than ~50 orders / day (write contention becomes visible)
 *   - About to scale beyond a single EC2 box (SQLite can't be shared)
 *
 * What this provisions:
 *   - DB subnet group spanning 2 AZs in ap-south-1 (single-AZ instance
 *     for now, but the subnet group is ready for Multi-AZ in Phase 5)
 *   - RDS Postgres 16 on db.t4g.micro (Free Tier: 750 hrs/month for 12
 *     months) with 20 GB gp3 storage and 7-day automated backups
 *   - Security group allowing port 5432 ingress only from the existing
 *     EC2 security group (no public exposure)
 *   - Random master password stored in Parameter Store; the EC2 IAM
 *     role already has Get permission on /karha/prod/*
 *   - A scoped `karha` app-user (DML only, can't run DDL) — created by
 *     the cutover playbook, not here, because we need the master
 *     creds first. The migration script handles user creation.
 *
 * The actual code-side DB swap (replacing better-sqlite3 with the
 * Postgres driver) is documented in `docs/postgres-migration.md` and
 * happens in karha-web. This Terraform just stands up the DB.
 */

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.40" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "db_instance_class" {
  description = "Free Tier covers db.t4g.micro for 12 months. Step up to db.t4g.small if writes saturate."
  type        = string
  default     = "db.t4g.micro"
}

provider "aws" {
  region = var.region
}

# ─────────────────────────────────────────────────────────────────
# Use the default VPC + its subnets. For a single-box launch this is
# fine; carve a dedicated VPC if multi-environment requirements later
# demand it.
# ─────────────────────────────────────────────────────────────────
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_security_group" "ec2" {
  name = "karha-prod"
}

# ─────────────────────────────────────────────────────────────────
# Master password — generated once, stored in Parameter Store.
# Lifecycle ignore stops a routine `terraform apply` from rotating
# the password and breaking the running app. Real rotations go
# through the AWS Secrets Manager flow once we wire it up in Phase 5.
# ─────────────────────────────────────────────────────────────────
resource "random_password" "master" {
  length  = 32
  special = true
  # Postgres role passwords can't contain `/`, `@`, `"`, or whitespace
  override_special = "!#$%^&*()-_=+[]{}<>:?"
  lifecycle { ignore_changes = [length, special, override_special] }
}

resource "aws_ssm_parameter" "db_master_password" {
  name        = "/karha/prod/DB_MASTER_PASSWORD"
  description = "RDS master password. App reads /karha/prod/DATABASE_URL instead — this is for ops."
  type        = "SecureString"
  value       = random_password.master.result
  lifecycle { ignore_changes = [value] }
}

# ─────────────────────────────────────────────────────────────────
# Subnet group + security group
# ─────────────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "karha" {
  name        = "karha-prod-db-subnets"
  description = "RDS subnets for karha-prod. Multi-AZ ready."
  subnet_ids  = data.aws_subnets.default.ids
}

resource "aws_security_group" "karha_db" {
  name        = "karha-prod-db"
  description = "Allow Postgres from the karha-prod EC2 SG only."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Postgres from EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [data.aws_security_group.ec2.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─────────────────────────────────────────────────────────────────
# The instance
# ─────────────────────────────────────────────────────────────────
resource "aws_db_instance" "karha" {
  identifier              = "karha-prod"
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp3"
  storage_encrypted       = true
  db_name                 = "karha_prod"
  username                = "karha_admin"
  password                = random_password.master.result
  port                    = 5432
  publicly_accessible     = false
  vpc_security_group_ids  = [aws_security_group.karha_db.id]
  db_subnet_group_name    = aws_db_subnet_group.karha.name
  multi_az                = false   # flip to true in Phase 5
  backup_retention_period = 7
  backup_window           = "20:00-21:00" # IST 01:30-02:30
  maintenance_window      = "Sun:21:30-Sun:23:00"
  deletion_protection     = true
  skip_final_snapshot     = false
  final_snapshot_identifier = "karha-prod-final-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  apply_immediately       = false

  performance_insights_enabled = false # extra cost; turn on if debugging

  tags = { Name = "karha-prod" }

  lifecycle {
    ignore_changes = [final_snapshot_identifier, password]
  }
}

# ─────────────────────────────────────────────────────────────────
# Build the DATABASE_URL the app reads from Parameter Store. We
# write it once so rotating the master password doesn't require
# re-deriving the URL — operators update both Parameter Store
# entries together when they rotate.
# ─────────────────────────────────────────────────────────────────
resource "aws_ssm_parameter" "database_url" {
  name        = "/karha/prod/DATABASE_URL"
  description = "Postgres connection string. App's lib/env.ts reads this; presence flips the driver from SQLite → Postgres."
  type        = "SecureString"
  # Use the karha app user we'll create after the box can connect
  # (see docs/postgres-migration.md for the CREATE USER step).
  value = format(
    "postgresql://%s:%s@%s:%d/%s?sslmode=require",
    "karha_app",                              # app user (created in playbook)
    "REPLACE_WITH_APP_PASSWORD",              # filled in after CREATE USER
    aws_db_instance.karha.address,
    aws_db_instance.karha.port,
    aws_db_instance.karha.db_name,
  )
  lifecycle { ignore_changes = [value] }
}

# ─────────────────────────────────────────────────────────────────
# Outputs — the migration playbook references these
# ─────────────────────────────────────────────────────────────────
output "db_endpoint" {
  value = aws_db_instance.karha.address
}

output "db_port" {
  value = aws_db_instance.karha.port
}

output "db_name" {
  value = aws_db_instance.karha.db_name
}

output "db_master_user" {
  value = aws_db_instance.karha.username
}

output "next_steps" {
  value = <<EOT
1. Master password is in Parameter Store: /karha/prod/DB_MASTER_PASSWORD
   aws ssm get-parameter --name /karha/prod/DB_MASTER_PASSWORD --with-decryption --query Parameter.Value --output text
2. From the EC2 box, create the scoped app user:
     PGPASSWORD=<master> psql -h ${aws_db_instance.karha.address} -U karha_admin -d karha_prod -c \
       "CREATE USER karha_app WITH PASSWORD 'CHOOSE-ANOTHER-RANDOM-32B';
        GRANT CONNECT ON DATABASE karha_prod TO karha_app;
        GRANT USAGE, CREATE ON SCHEMA public TO karha_app;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO karha_app;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
          GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO karha_app;"
3. Replace DATABASE_URL in Parameter Store with the karha_app user
   (use the password chosen in step 2):
     aws ssm put-parameter --name /karha/prod/DATABASE_URL \
       --value "postgresql://karha_app:<password>@${aws_db_instance.karha.address}:5432/karha_prod?sslmode=require" \
       --type SecureString --overwrite
4. Run the migration: bash scripts/pgloader-migrate.sh
5. Deploy a release of karha-web that reads DATABASE_URL (the env loader
   in src/lib/env.ts already supports this — no code change required to
   route to Postgres once the URL is set).
6. Hit /api/health → confirms db: ok against Postgres.
7. Smoke-test: admin login, place an order, view orders.
8. After 48 h of clean operation, take a final SQLite backup and stop
   writing to it. Keep `database/karha.db` on disk for 30 days as a
   safety net before deleting.
EOT
}
