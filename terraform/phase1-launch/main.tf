/**
 * Phase 1 — Day-1 launch infrastructure for karha.in
 *
 * Provisions a single EC2 t3.micro in ap-south-1 (Mumbai) with:
 *   - 30 GB gp3 EBS root volume
 *   - Elastic IP (free while attached)
 *   - Security group: SSH from your IP, HTTPS / HTTP from anywhere
 *   - S3 bucket for daily DB + uploads backups, 30-day lifecycle
 *   - IAM role + instance profile so the box pulls secrets from
 *     Parameter Store and writes backups to S3 without long-lived
 *     access keys living on disk
 *   - Parameter Store entries for JWT_SECRET / CRON_SECRET (random
 *     32-byte hex strings — admins rotate via the AWS console)
 *   - CloudWatch billing alarm at $10/mo
 *
 * Free Tier coverage: 750 hrs/mo EC2 + 30 GB EBS + 5 GB S3 for 12
 * months. Steady-state cost during the trial: $0. After the trial:
 * ~$11/mo (t3.micro on-demand) plus a few cents for S3 PUTs.
 */

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.40" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "region" {
  description = "AWS region — Mumbai for Indian audience latency."
  type        = string
  default     = "ap-south-1"
}

variable "ssh_ingress_cidr" {
  description = "Your home / office IPv4 CIDR for SSH access (e.g. 203.0.113.42/32). DO NOT leave open to 0.0.0.0/0."
  type        = string
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair you control. Create it manually before running terraform."
  type        = string
  default     = "karha-prod"
}

variable "domain_admin_email" {
  description = "Email shown to billing alarm + Let's Encrypt registrations."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo bootstrap.sh clones — keep this in sync with where the app code lives."
  type        = string
  default     = "https://github.com/namanguptaiitkgp/Karha.git"
}

provider "aws" {
  region = var.region
}

# ─────────────────────────────────────────────────────────────────
# Discover the latest Amazon Linux 2023 ARM-compatible AMI dynamically
# so we don't pin to an AMI id that goes stale every quarter.
# ─────────────────────────────────────────────────────────────────
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ─────────────────────────────────────────────────────────────────
# Random secrets — generated once, written to Parameter Store, then
# read by the app at boot via scripts/load-secrets.sh.
#
# Lifecycle rule keeps Terraform from regenerating these on apply
# (which would invalidate every issued JWT). Rotate manually via:
#   1. New value in Parameter Store
#   2. pm2 reload karha
#
# Or, more carefully, terraform taint then apply.
# ─────────────────────────────────────────────────────────────────
resource "random_id" "jwt_secret" {
  byte_length = 32
  lifecycle { ignore_changes = [byte_length] }
}

resource "random_id" "cron_secret" {
  byte_length = 32
  lifecycle { ignore_changes = [byte_length] }
}

resource "aws_ssm_parameter" "jwt_secret" {
  name        = "/karha/prod/JWT_SECRET"
  description = "Signs customer + admin JWTs. Read at boot; rotate via console + pm2 restart."
  type        = "SecureString"
  value       = random_id.jwt_secret.hex
}

resource "aws_ssm_parameter" "cron_secret" {
  name        = "/karha/prod/CRON_SECRET"
  description = "Optional: gates POST /api/cron/subscriptions when called by EventBridge / external schedulers."
  type        = "SecureString"
  value       = random_id.cron_secret.hex
}

# ─────────────────────────────────────────────────────────────────
# S3 bucket for daily DB + upload backups
# ─────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "backups" {
  bucket = "karha-prod-backups"
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "expire-after-30-days"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 30 }
  }
}

# ─────────────────────────────────────────────────────────────────
# IAM — instance profile that lets the EC2 box read its own secrets
# from Parameter Store and write backups to S3. No long-lived access
# keys ever land on the box.
# ─────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karha_ec2" {
  name               = "karha-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "karha_ec2" {
  statement {
    sid     = "BackupsToS3"
    actions = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetObject"]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
  }
  statement {
    sid     = "ReadSecretsFromParameterStore"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${var.region}:*:parameter/karha/prod/*"
    ]
  }
  statement {
    sid       = "DecryptParameterStoreSecureStrings"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
  statement {
    sid     = "WriteAppLogsToCloudWatch"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:${var.region}:*:log-group:karha/*"]
  }
}

resource "aws_iam_role_policy" "karha_ec2" {
  role   = aws_iam_role.karha_ec2.id
  name   = "karha-ec2-inline"
  policy = data.aws_iam_policy_document.karha_ec2.json
}

resource "aws_iam_instance_profile" "karha_ec2" {
  name = "karha-ec2-profile"
  role = aws_iam_role.karha_ec2.name
}

# ─────────────────────────────────────────────────────────────────
# Network — security group with intentionally narrow SSH ingress
# ─────────────────────────────────────────────────────────────────
resource "aws_security_group" "karha" {
  name        = "karha-prod"
  description = "karha.in production EC2 instance"

  ingress {
    description = "SSH from your home IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }
  ingress {
    description = "HTTP — handled by certbot challenge + Nginx 301 redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound for npm install, GitHub, AWS APIs, Let's Encrypt"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─────────────────────────────────────────────────────────────────
# EC2 instance + Elastic IP
# ─────────────────────────────────────────────────────────────────
resource "aws_instance" "karha" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = "t3.micro"
  key_name             = var.key_pair_name
  iam_instance_profile = aws_iam_instance_profile.karha_ec2.name
  vpc_security_group_ids = [aws_security_group.karha.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  /*
   * The user_data here is intentionally minimal — it just installs
   * the basics so we can SSH in and run scripts/bootstrap.sh.
   * Heavy lifting lives in the script (which is in version control)
   * so re-bootstrapping a replacement box doesn't require a tf apply.
   */
  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y git curl
  EOF

  tags = { Name = "karha-prod" }

  lifecycle {
    /* Avoid a destroy-and-recreate on AMI bumps — apply a swap manually
     * via the runbook (stop, snapshot, replace). The box is a pet; this
     * stops Terraform from accidentally killing the cattle. */
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "karha" {
  domain = "vpc"
  tags   = { Name = "karha-prod" }
}

resource "aws_eip_association" "karha" {
  instance_id   = aws_instance.karha.id
  allocation_id = aws_eip.karha.id
}

# ─────────────────────────────────────────────────────────────────
# CloudWatch billing alarm — emails when total monthly charge crosses
# $10 (well under the $100 credit, gives headroom to react). AWS
# Budgets-based alerting is a separate console-only step (free).
# ─────────────────────────────────────────────────────────────────
resource "aws_sns_topic" "billing_alarms" {
  name = "karha-billing-alarms"
}

resource "aws_sns_topic_subscription" "billing_email" {
  topic_arn = aws_sns_topic.billing_alarms.arn
  protocol  = "email"
  endpoint  = var.domain_admin_email
}

resource "aws_cloudwatch_metric_alarm" "billing" {
  /* CloudWatch billing alarms only emit in us-east-1 — this provider
   * alias scopes just the alarm to that region. */
  provider = aws.us_east_1

  alarm_name          = "karha-billing-monthly"
  alarm_description   = "Total monthly AWS charges crossed the threshold."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 86400
  statistic           = "Maximum"
  threshold           = 10
  alarm_actions       = [aws_sns_topic.billing_alarms.arn]
  dimensions = {
    Currency = "USD"
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# ─────────────────────────────────────────────────────────────────
# Outputs — Terraform prints these after `apply` so the runbook
# steps are unambiguous.
# ─────────────────────────────────────────────────────────────────
output "elastic_ip" {
  description = "Set both A records (@ and www) to this in GoDaddy."
  value       = aws_eip.karha.public_ip
}

output "ssh_command" {
  description = "Connect to the box."
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_eip.karha.public_ip}"
}

output "backups_bucket" {
  description = "Daily backup target."
  value       = aws_s3_bucket.backups.bucket
}

output "next_steps" {
  value = <<EOT
1. Set GoDaddy DNS:  A @ ${aws_eip.karha.public_ip}  (TTL 600)
                     A www ${aws_eip.karha.public_ip}
2. Wait for propagation: dig karha.in @8.8.8.8
3. SSH in:  ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_eip.karha.public_ip}
4. Run bootstrap (clones the app, builds, starts PM2):
     curl -O https://raw.githubusercontent.com/namanguptaiitkgp/karha-infra/main/scripts/bootstrap.sh
     sudo bash bootstrap.sh ${var.domain_admin_email}
5. Verify:  curl -I https://karha.in  -> 200
EOT
}
