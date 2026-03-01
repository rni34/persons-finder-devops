# ---------- ALB Access Logs ----------
# PERF03-BP01: Collect request-level metrics for performance analysis.
# ALB access logs capture per-request latency (target_processing_time,
# response_processing_time), status codes, and request size — data that
# Prometheus pod metrics alone cannot provide (ALB-to-pod latency, TLS
# handshake time, WAF evaluation time).

resource "aws_s3_bucket" "alb_access_logs" {
  bucket = "${var.cluster_name}-alb-access-logs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.cluster_name}-alb-access-logs"
  }
}

data "aws_caller_identity" "current" {}

# CKV_AWS_21 / CIS AWS Foundations 2.1.3 — versioning protects audit logs against
# accidental deletion or malicious tampering. Access logs are append-only so
# versioning adds negligible cost; the 90-day lifecycle policy expires all versions.
resource "aws_s3_bucket_versioning" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    expiration {
      days = 90
    }
    # Clean up old versions after 30 additional days (120 total) to prevent
    # unbounded storage growth from versioning while retaining a recovery window.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      # ALB access log delivery only supports SSE-S3 (AES256), NOT SSE-KMS.
      # The log delivery service writes logs directly and has no KMS permissions.
      # Using aws:kms causes silent delivery failure — no logs, no error.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_access_logs" {
  bucket                  = aws_s3_bucket.alb_access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.alb_access_logs.arn,
          "${aws_s3_bucket.alb_access_logs.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      # Current AWS-recommended principal for ALB access log delivery.
      # Replaces two deprecated methods:
      #   1. aws_elb_service_account (legacy per-region account IDs, pre-Aug 2022 only)
      #   2. delivery.logs.amazonaws.com with s3:x-amz-acl condition (Outposts only;
      #      fails with BucketOwnerEnforced — the S3 default since April 2023)
      # See: docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
      {
        Sid       = "ALBAccessLogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_access_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:elasticloadbalancing:${var.region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"
          }
        }
      }
    ]
  })
}

output "alb_access_logs_bucket" {
  description = "S3 bucket name for ALB access logs — use in ingress annotation"
  value       = aws_s3_bucket.alb_access_logs.id
}
