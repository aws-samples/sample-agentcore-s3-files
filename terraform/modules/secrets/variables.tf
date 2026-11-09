variable "project_name" {
  type        = string
  description = "Project name prefix"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
}

variable "gitlab_token" {
  type        = string
  description = "GitLab access token stored as the secret value. Defaults to empty so the secret can be created before a token is supplied; set it via TF_VAR_gitlab_token, an untracked *.auto.tfvars, or the AWS console. NEVER commit a real token."
  default     = ""
  sensitive   = true
}

variable "recovery_window_in_days" {
  type        = number
  description = "Secrets Manager recovery window (0 = delete immediately, useful for dev teardown)."
  default     = 0
}
