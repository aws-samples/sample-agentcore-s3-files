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
  description = "VPC ID for the runtimes and S3 Files mount targets"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the VPC runtimes and mount targets"
}

variable "access_point_arns" {
  type        = map(string)
  description = "Dedicated S3 Files access point ARNs keyed by MCP server name (workspace, gitlab)."
  default     = {}
}

variable "access_point_mount_paths" {
  type        = map(string)
  description = "Dedicated container mount paths keyed by MCP server name."
  default     = {}
}

variable "mount_path" {
  type        = string
  description = "Logical S3 Files mount root used by the MCP application code"
  default     = "/mnt"
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

variable "create_runtimes" {
  type        = bool
  description = "Whether to create the MCP server runtimes. Plan-time flag (ECR images must exist first)."
  default     = false
}

variable "mcp_servers" {
  type = map(object({
    description   = string
    container_uri = optional(string, "")
  }))
  description = "MCP servers to create (mount S3 Files, protocol=MCP). Keys: workspace, gitlab."
  default     = {}
}

variable "gitlab_secret_arn" {
  type        = string
  description = "Secrets Manager ARN holding the GitLab token (granted to the gitlab MCP server)."
  default     = ""
}

variable "gitlab_kms_key_arn" {
  type        = string
  description = "KMS key ARN encrypting the GitLab token secret. The runtime receives decrypt access only through Secrets Manager."
}

variable "prompt_model_id" {
  type        = string
  description = "Bedrock inference-profile id used to scope the agent runtime role."
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
  description = "Image tag appended to the derived ECR URL for each runtime image."
  default     = "latest"
}
