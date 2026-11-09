output "gateway_id" {
  description = "AgentCore Gateway ID (empty if not created)."
  value       = var.create_gateway ? aws_bedrockagentcore_gateway.this[0].gateway_id : ""
}

output "gateway_arn" {
  description = "AgentCore Gateway ARN (empty if not created)."
  value       = var.create_gateway ? aws_bedrockagentcore_gateway.this[0].gateway_arn : ""
}

output "gateway_url" {
  description = "AgentCore Gateway MCP endpoint URL — inject into the agents as GATEWAY_URL."
  value       = var.create_gateway ? aws_bedrockagentcore_gateway.this[0].gateway_url : ""
}
