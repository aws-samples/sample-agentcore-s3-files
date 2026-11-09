variable "project_name" {
  type        = string
  description = "Project name prefix"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for the agent runtimes (used only for the precondition check)"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the agent runtimes"
}

variable "security_group_id" {
  type        = string
  description = "Shared security group ID (from the mcp module) the agents run in."
}

variable "runtime_role_arn" {
  type        = string
  description = "Agent-only execution role ARN (from the mcp module)."
}

variable "runtime_logs_kms_key_arn" {
  type        = string
  description = "KMS key ARN used to encrypt AgentCore runtime CloudWatch log groups."
}

variable "runtime_log_retention_days" {
  type        = number
  description = "Retention period for AgentCore runtime CloudWatch log groups."
  default     = 365
}

variable "gateway_url" {
  type        = string
  description = "AgentCore Gateway MCP endpoint URL, injected into the agents as GATEWAY_URL. Empty until the gateway is created."
  default     = ""
}

variable "mcp_runtime_ids" {
  type        = map(string)
  description = "Map of MCP server name -> runtime id (from the mcp module). Injected as *_MCP_RUNTIME_ID env vars."
  default     = {}
}

variable "create_runtimes" {
  type        = bool
  description = "Whether to create the agent runtimes. MUST be a plan-time value. Gated because the agents reference ECR images that must be built and pushed first (Phase 1 -> push -> Phase 2), NOT because of S3 Files."
  default     = false
}

variable "prompt_model_id" {
  type        = string
  description = "Bedrock model id / inference-profile id passed to the agents as BEDROCK_MODEL_ID."
}

variable "agents" {
  type = map(object({
    description   = string
    container_uri = optional(string, "")
  }))
  description = "Agents to create (A2A, no mount). Keys: analyzer, reviewer."
  default     = {}
}

variable "idle_runtime_session_timeout" {
  type        = number
  description = "Seconds of idle time before an AgentCore runtime session is reclaimed"
  default     = 900
}

variable "max_lifetime" {
  type        = number
  description = "Maximum lifetime (seconds) of an AgentCore runtime session"
  default     = 28800
}

variable "ecr_repository_urls" {
  type        = map(string)
  description = "Map of image name -> ECR repository URL (from the ecr module)."
  default     = {}
}

variable "image_tag" {
  type        = string
  description = "Image tag appended to the derived ECR URL for each agent image."
  default     = "latest"
}
