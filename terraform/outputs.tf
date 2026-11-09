output "vpc_id" {
  description = "Effective VPC ID (created or from config.yaml)."
  value       = local.effective_vpc_id
}

output "private_subnet_ids" {
  description = "Effective private subnet IDs used for mount targets and runtimes."
  value       = local.effective_private_subnet_ids
}

output "workspace_bucket_name" {
  description = "S3 bucket backing the shared agent workspaces."
  value       = module.s3files.bucket_name
}

output "s3files_filesystem_id" {
  description = "S3 Files filesystem ID (populated after the S3 Files CLI provisioning runs during apply)."
  value       = module.s3files.filesystem_id
}

output "s3files_access_point_arns" {
  description = "Dedicated S3 Files access point ARNs for repositories and workspaces."
  value       = module.s3files.access_point_arns
}

output "workspace_kms_key_arn" {
  description = "Primary-region KMS key encrypting workspace objects."
  value       = module.s3files.workspace_kms_key_arn
}

output "runtime_logs_kms_key_arn" {
  description = "KMS key encrypting AgentCore runtime CloudWatch log groups."
  value       = aws_kms_key.agentcore_runtime_logs.arn
}

output "agentcore_security_group_id" {
  description = "Security group shared by AgentCore runtimes and S3 Files mount targets."
  value       = module.mcp.security_group_id
}

output "mcp_runtime_arns" {
  description = "Map of MCP server name -> runtime ARN (workspace, gitlab)."
  value       = module.mcp.mcp_runtime_arns
}

output "analyzer_runtime_arn" {
  description = "Analyzer (Agent 1: tech + security) runtime ARN."
  value       = module.agentcore.analyzer_runtime_arn
}

output "analyzer_runtime_id" {
  description = "Analyzer runtime id — export as ANALYZER_RUNTIME_ID for scripts/start_review.py."
  value       = module.agentcore.analyzer_runtime_id
}

output "reviewer_runtime_arn" {
  description = "Reviewer (Agent 2: finalizer, posts to GitLab) runtime ARN."
  value       = module.agentcore.reviewer_runtime_arn
}

output "ecr_repository_urls" {
  description = "Map of image name -> ECR repository URL (docker push target)."
  value       = module.ecr.repository_urls
}

output "aws_region" {
  description = "AWS region the stack is deployed into (from var.aws_region) — the single source of truth for helper scripts."
  value       = var.aws_region
}

output "project_name" {
  description = "Project name prefix — the single source of truth for helper scripts (teardown/verify)."
  value       = var.project_name
}

output "environment" {
  description = "Environment name — combined with project_name to derive resource name prefixes."
  value       = var.environment
}

output "gitlab_secret_arn" {
  description = "ARN of the GitLab token secret wired into the gitlab MCP (empty if not created / using an external ARN)."
  value       = local.gitlab_secret_arn
}

output "gateway_url" {
  description = "AgentCore Gateway MCP endpoint (GATEWAY_URL injected into the agents). Empty until Phase 2."
  value       = module.gateway.gateway_url
}
