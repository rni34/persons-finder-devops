# ---------- IAM for External Secrets Operator (IRSA) ----------

# Policy: allow ESO to read the specific secret
resource "aws_iam_policy" "eso_secrets_access" {
  name        = "${var.cluster_name}-eso-secrets-access"
  description = "Allow External Secrets Operator to read persons-finder secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.openai_api_key.arn
      }
    ]
  })
}

# IRSA role for ESO service account
module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-eso"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets-sa", "persons-finder:eso-sa"]
    }
  }

  role_policy_arns = {
    secrets = aws_iam_policy.eso_secrets_access.arn
  }

  tags = {
    Project     = "persons-finder"
    Environment = "dev"
  }
}

# ---------- ECR Repository ----------
resource "aws_ecr_repository" "app" {
  name                 = "persons-finder"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project     = "persons-finder"
    Environment = "dev"
  }
}

# ---------- ECR Lifecycle Policy ----------
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
