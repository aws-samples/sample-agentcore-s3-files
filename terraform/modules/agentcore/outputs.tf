output "analyzer_runtime_arn" {
  description = "Analyzer (Agent 1: tech + security) runtime ARN"
  value       = length(aws_bedrockagentcore_agent_runtime.analyzer) > 0 ? aws_bedrockagentcore_agent_runtime.analyzer[0].agent_runtime_arn : ""
}

output "analyzer_runtime_id" {
  description = "Analyzer runtime id — pass to scripts/start_review.py"
  value       = length(aws_bedrockagentcore_agent_runtime.analyzer) > 0 ? aws_bedrockagentcore_agent_runtime.analyzer[0].agent_runtime_id : ""
}

output "reviewer_runtime_arn" {
  description = "Reviewer (Agent 2: finalizer, posts to GitLab) runtime ARN"
  value       = length(aws_bedrockagentcore_agent_runtime.reviewer) > 0 ? aws_bedrockagentcore_agent_runtime.reviewer[0].agent_runtime_arn : ""
}
