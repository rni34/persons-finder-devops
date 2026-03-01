# ---------- Remote State Backend (S3) ----------
# Uncomment and configure to use remote state instead of local.
#
# terraform {
#   backend "s3" {
#     bucket       = "persons-finder-terraform-state"
#     key          = "eks/terraform.tfstate"
#     region       = "us-east-1"
#     encrypt      = true
#     use_lockfile = true          # Native S3 locking (Terraform >= 1.10, replaces DynamoDB)
#     kms_key_id   = "alias/terraform-state"  # Customer-managed KMS key (omit for SSE-S3)
#
#     # Legacy DynamoDB locking (Terraform < 1.10) — deprecated in 1.11+
#     # dynamodb_table = "persons-finder-terraform-lock"
#   }
# }
#
# ── Bootstrap the backend resources ──────────────────────────────────
#
#   # 1. Create S3 bucket
#   aws s3api create-bucket --bucket persons-finder-terraform-state --region us-east-1
#
#   # 2. Enable versioning (rollback on state corruption)
#   aws s3api put-bucket-versioning --bucket persons-finder-terraform-state \
#     --versioning-configuration Status=Enabled
#
#   # 3. Block all public access
#   aws s3api put-public-access-block --bucket persons-finder-terraform-state \
#     --public-access-block-configuration \
#     BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
#
#   # 4. Enforce TLS-only access (bucket policy)
#   aws s3api put-bucket-policy --bucket persons-finder-terraform-state --policy '{
#     "Version": "2012-10-17",
#     "Statement": [{
#       "Sid": "EnforceTLS",
#       "Effect": "Deny",
#       "Principal": "*",
#       "Action": "s3:*",
#       "Resource": [
#         "arn:aws:s3:::persons-finder-terraform-state",
#         "arn:aws:s3:::persons-finder-terraform-state/*"
#       ],
#       "Condition": { "Bool": { "aws:SecureTransport": "false" } }
#     }]
#   }'
#
#   # 5. (Optional) Create KMS key for state encryption
#   KEY_ID=$(aws kms create-key --query KeyMetadata.KeyId --output text)
#   aws kms enable-key-rotation --key-id "$KEY_ID"   # CIS AWS 2.8 — required for all CMKs
#   aws kms create-alias --alias-name alias/terraform-state --target-key-id "$KEY_ID"
