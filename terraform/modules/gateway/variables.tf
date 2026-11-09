variable "project_name" {
  type        = string
  description = "Project name prefix"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
}

variable "create_gateway" {
  type        = bool
  description = "Whether to create the AgentCore Gateway + MCP-runtime targets. Plan-time flag — gate it on the same signal as the runtimes (create_runtimes) since the targets reference the MCP runtime ARNs."
  default     = false
}

variable "workspace_mcp_runtime_arn" {
  type        = string
  description = "AgentCore Runtime ARN for the workspace MCP server (gateway target endpoint). Empty disables that target."
  default     = ""
}

variable "gitlab_mcp_runtime_arn" {
  type        = string
  description = "AgentCore Runtime ARN for the gitlab MCP server (gateway target endpoint). Empty disables that target."
  default     = ""
}

variable "session_timeout_in_seconds" {
  type        = number
  description = "MCP session timeout for the gateway."
  default     = 3600
}
