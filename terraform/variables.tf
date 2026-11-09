variable "project_name" {
  description = "Project name prefix for all resources."
  type        = string
  default     = "agentcore-s3files"
}

variable "environment" {
  description = "Deployment environment — selects environments/<env>/config.yaml."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-southeast-1"
}

variable "replica_region" {
  description = "Secondary AWS region for S3 cross-region replication of the workspace + access-log buckets (checkov CKV_AWS_144). Must differ from aws_region."
  type        = string
  default     = "ap-southeast-2"
}

variable "log_level" {
  description = "Application log level override (DEBUG|INFO|WARNING|ERROR). Falls back to config.yaml."
  type        = string
  default     = null
}

variable "gitlab_token" {
  description = "GitLab access token for the gitlab MCP secret. Supply out-of-band via TF_VAR_gitlab_token or an untracked *.auto.tfvars — NEVER commit it. Only used when secrets.create_gitlab_secret is true."
  type        = string
  default     = ""
  sensitive   = true
}
