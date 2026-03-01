output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}

output "eso_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = module.eso_irsa.iam_role_arn
}

output "secret_arn" {
  description = "Secrets Manager secret ARN"
  value       = aws_secretsmanager_secret.openai_api_key.arn
}

output "security_notifications_topic_arn" {
  description = "SNS topic ARN for security notifications (GuardDuty + ECR scan findings). Subscribe to receive alerts."
  value       = aws_sns_topic.guardduty_findings.arn
}
