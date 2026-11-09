output "repository_urls" {
  description = "Map of image name -> ECR repository URL (push target)"
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  description = "Map of image name -> ECR repository ARN"
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}
