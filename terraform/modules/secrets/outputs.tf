output "gitlab_secret_arn" {
  description = "ARN of the GitLab token secret. Wired into the gitlab MCP runtime as GITLAB_SECRET_ARN."
  value       = aws_secretsmanager_secret.gitlab.arn
}

output "gitlab_secret_name" {
  description = "Name of the GitLab token secret."
  value       = aws_secretsmanager_secret.gitlab.name
}

output "gitlab_kms_key_arn" {
  description = "ARN of the customer-managed KMS key encrypting the GitLab token secret."
  value       = aws_kms_key.gitlab.arn
}
