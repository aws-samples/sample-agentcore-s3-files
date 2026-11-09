output "security_group_id" {
  description = "Security group shared by all runtimes (MCP + agents) and S3 Files mount targets."
  value       = aws_security_group.agentcore.id
}

output "agent_runtime_role_arn" {
  description = "Execution role ARN assumed only by the analyzer and reviewer agents."
  value       = aws_iam_role.runtime["agent"].arn
  depends_on  = [time_sleep.wait_for_runtime_iam]
}

output "workspace_mcp_runtime_role_arn" {
  description = "Execution role ARN assumed only by the workspace MCP runtime."
  value       = aws_iam_role.runtime["workspace"].arn
}

output "gitlab_mcp_runtime_role_arn" {
  description = "Execution role ARN assumed only by the GitLab MCP runtime."
  value       = aws_iam_role.runtime["gitlab"].arn
}

output "mcp_runtime_arns" {
  description = "Map of MCP server name -> runtime ARN (workspace, gitlab)."
  value       = { for k, r in aws_bedrockagentcore_agent_runtime.mcp : k => r.agent_runtime_arn }
}

output "mcp_runtime_ids" {
  description = "Map of MCP server name -> runtime id (workspace, gitlab)."
  value       = { for k, r in aws_bedrockagentcore_agent_runtime.mcp : k => r.agent_runtime_id }
}
