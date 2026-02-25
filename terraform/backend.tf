# ---------- Remote State Backend (S3 + DynamoDB) ----------
# Uncomment and configure to use remote state instead of local.
# This ensures reproducible state across team members and CI.
#
# terraform {
#   backend "s3" {
#     bucket         = "persons-finder-terraform-state"
#     key            = "eks/terraform.tfstate"
#     region         = "us-east-1"
#     encrypt        = true
#     dynamodb_table = "persons-finder-terraform-lock"
#   }
# }
#
# Create the backend resources first:
#   aws s3api create-bucket --bucket persons-finder-terraform-state --region us-east-1
#   aws s3api put-bucket-versioning --bucket persons-finder-terraform-state --versioning-configuration Status=Enabled
#   aws dynamodb create-table --table-name persons-finder-terraform-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST
