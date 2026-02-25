# ---------- AWS Secrets Manager for OPENAI_API_KEY ----------
resource "aws_secretsmanager_secret" "openai_api_key" {
  name                    = "persons-finder/openai-api-key"
  description             = "OpenAI API key for persons-finder application"
  recovery_window_in_days = 7

  # KMS CMK encryption (CKV_AWS_149) — AWS-managed key is sufficient for dev;
  # a customer-managed CMK would be used in production for key rotation control
  # kms_key_id = aws_kms_key.secrets.arn

  tags = {
    Project     = "persons-finder"
    Environment = "dev"
  }
}

# Placeholder value — replace via AWS Console or CLI after apply
resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id = aws_secretsmanager_secret.openai_api_key.id
  secret_string = jsonencode({
    OPENAI_API_KEY = "REPLACE_ME_VIA_CONSOLE"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
