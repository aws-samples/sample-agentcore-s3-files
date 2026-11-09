variable "project_name" {
  type        = string
  description = "Project name prefix"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
}

variable "workspace_prefix" {
  type        = string
  description = "S3 key prefix under which agent workspaces are created (lifecycle-scoped)"
  default     = "agentcore/workspaces/"
}

variable "retention_days" {
  type        = number
  description = "Days to retain workspace artifacts in S3 before auto-expiry"
  default     = 30
}

variable "create_s3files" {
  type        = bool
  description = "Whether to create the S3 Files filesystem, mount target(s), and dedicated access points. Module-internal switch (the root hardcodes true) — set false only to stand up the bucket + IAM role WITHOUT S3 Files. This is NOT a deploy-phase toggle: when true, the filesystem + access points are created and the apply-time ARNs are resolved within a single apply."
  default     = false
}

variable "vpc_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the S3 Files mount targets (one mount target per subnet)"
  default     = []
}

variable "security_group_id" {
  type        = string
  description = "Security group ID for the S3 Files mount targets (same SG as the AgentCore runtimes)"
  default     = ""
}
