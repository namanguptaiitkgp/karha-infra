/**
 * Phase 3 — S3 uploads bucket + CloudFront distribution.
 *
 * Run this after Phase 1 has been live for long enough that you have
 * the cutover triggers (uploads > 1 GB on the EBS volume OR
 * CloudFront-billed egress would beat EBS+EC2 for image bandwidth).
 *
 * What this provisions:
 *   - S3 bucket `karha-prod-uploads` (private, OAC for CloudFront only)
 *   - CloudFront distribution with two behaviours:
 *       * `/uploads/*`  → S3 origin (year-long cache, immutable)
 *       * `*`           → EC2 origin (default cache 0 for HTML)
 *   - ACM cert in us-east-1 (CloudFront requires this region)
 *   - IAM policy attached to the existing karha-ec2-role so the box
 *     can PutObject / DeleteObject for upload writes (the local FS
 *     fallback in storage.ts disappears once STORAGE_BACKEND=s3)
 *
 * After `terraform apply`:
 *   1. Add a DNS validation CNAME for the ACM cert in GoDaddy
 *      (Terraform output prints the records).
 *   2. One-time mirror existing uploads to S3:
 *        aws s3 sync /home/karha/app/public/uploads/ s3://karha-prod-uploads/
 *   3. Update Parameter Store:
 *        /karha/prod/STORAGE_BACKEND  =  s3
 *        /karha/prod/S3_BUCKET        =  karha-prod-uploads
 *      (and add corresponding lines to .env.production via load-secrets.sh)
 *   4. Restart PM2 — uploads now route through writeUpload() → S3.
 *   5. Move the karha.in / www.karha.in DNS records from A → CNAME
 *      pointing at the CloudFront domain (Terraform output).
 *
 * Cost: ~$2-6/month depending on egress. CloudFront free tier covers
 * 1 TB egress / 10 M requests for the first 12 months.
 */

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "domain_primary" {
  type    = string
  default = "karha.in"
}

variable "ec2_origin_dns" {
  description = "Stable hostname for the EC2 box. Use the karha.in DNS (after DNS update) or the EC2 public DNS."
  type        = string
}

provider "aws" {
  region = var.region
}

# CloudFront ACM certificates MUST live in us-east-1 — separate provider.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

# Reference the existing IAM role provisioned by Phase 1.
data "aws_iam_role" "karha_ec2" {
  name = "karha-ec2-role"
}

# ─────────────────────────────────────────────────────────────────
# S3 uploads bucket
# ─────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "uploads" {
  bucket = "karha-prod-uploads"
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  cors_rule {
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["https://${var.domain_primary}", "https://www.${var.domain_primary}"]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

# ─────────────────────────────────────────────────────────────────
# IAM — let the existing EC2 role write to the uploads bucket
# ─────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "ec2_uploads" {
  statement {
    actions = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.uploads.arn,
      "${aws_s3_bucket.uploads.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "ec2_uploads" {
  role   = data.aws_iam_role.karha_ec2.id
  name   = "karha-ec2-uploads"
  policy = data.aws_iam_policy_document.ec2_uploads.json
}

# ─────────────────────────────────────────────────────────────────
# CloudFront — origin access control for S3, custom origin for EC2
# ─────────────────────────────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "uploads" {
  name                              = "karha-uploads-oac"
  description                       = "OAC for the uploads bucket so only CloudFront can read it."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_acm_certificate" "site" {
  provider          = aws.use1
  domain_name       = var.domain_primary
  subject_alternative_names = ["www.${var.domain_primary}"]
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = ""
  comment             = "karha.in — Phase 3 CDN"
  aliases             = [var.domain_primary, "www.${var.domain_primary}"]
  http_version        = "http2and3"
  price_class         = "PriceClass_200" # all edges except SA + Australia — cheaper

  # Origin 1 — S3 uploads
  origin {
    origin_id                = "uploads-s3"
    domain_name              = aws_s3_bucket.uploads.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.uploads.id
  }

  # Origin 2 — EC2 (Nginx) for everything else
  origin {
    origin_id   = "ec2-origin"
    domain_name = var.ec2_origin_dns
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # /uploads/* → S3 with year-long cache
  ordered_cache_behavior {
    path_pattern           = "/uploads/*"
    target_origin_id       = "uploads-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
  }

  # Default — EC2 with no cache for HTML
  default_cache_behavior {
    target_origin_id       = "ec2-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer — forwards Host, cookies, query strings
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.site.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ─────────────────────────────────────────────────────────────────
# Bucket policy — only the CloudFront distribution can read S3 objects
# ─────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "uploads_bucket" {
  statement {
    sid     = "AllowCloudFrontOACRead"
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.uploads.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  policy = data.aws_iam_policy_document.uploads_bucket.json
}

# ─────────────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────────────
output "uploads_bucket" {
  value = aws_s3_bucket.uploads.bucket
}

output "cloudfront_domain" {
  description = "Point karha.in CNAME records at this once ACM validates."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "acm_validation_records" {
  description = "Add these CNAMEs in GoDaddy DNS to validate the ACM cert."
  value = [
    for opt in aws_acm_certificate.site.domain_validation_options : {
      name  = opt.resource_record_name
      type  = opt.resource_record_type
      value = opt.resource_record_value
    }
  ]
}

output "cutover_steps" {
  value = <<EOT
1. Add the CNAMEs from acm_validation_records above to GoDaddy DNS.
2. aws acm wait certificate-validated --certificate-arn ${aws_acm_certificate.site.arn} --region us-east-1
3. Mirror existing uploads:
     ssh -i ~/.ssh/karha-prod.pem ec2-user@<elastic-ip>
     aws s3 sync /home/karha/app/public/uploads/ s3://${aws_s3_bucket.uploads.bucket}/
4. aws ssm put-parameter --name /karha/prod/STORAGE_BACKEND --value s3 --type String --overwrite
   aws ssm put-parameter --name /karha/prod/S3_BUCKET --value ${aws_s3_bucket.uploads.bucket} --type String --overwrite
5. Update bootstrap/.env.production load step (or scripts/load-secrets.sh) to read these,
   then `pm2 reload karha --update-env`.
6. In GoDaddy, swap the karha.in and www.karha.in records:
     A      → CNAME
     value  → ${aws_cloudfront_distribution.site.domain_name}
7. Verify a fresh upload lands in S3 and serves with `cf-cache-status: Hit` after first request.
EOT
}
