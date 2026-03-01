# ---------- KMS key for Secrets Manager encryption ----------
resource "aws_kms_key" "secrets" {
  description             = "CMK for persons-finder Secrets Manager secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  # KMS key deletion is irreversible — all encrypted secrets become permanently unrecoverable.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/persons-finder-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ---------- AWS Secrets Manager for OPENAI_API_KEY ----------
resource "aws_secretsmanager_secret" "openai_api_key" {
  name                    = "persons-finder/openai-api-key"
  description             = "OpenAI API key for persons-finder application"
  recovery_window_in_days = 7
  kms_key_id              = aws_kms_key.secrets.arn

  # Accidental deletion loses the API key; 7-day recovery window only helps if caught in time.
  lifecycle {
    prevent_destroy = true
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
