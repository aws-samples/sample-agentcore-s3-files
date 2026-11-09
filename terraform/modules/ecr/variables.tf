variable "project_name" {
  type        = string
  description = "Project name prefix"
}

variable "environment" {
  type        = string
  description = "Environment (dev, staging, prod)"
}

variable "repository_names" {
  type        = list(string)
  description = "Image names to create repositories for (e.g. analyzer-agent, reviewer-agent, workspace-mcp, gitlab-mcp). Repo = <project>-<env>-<name>."
  default     = []
}

# NOTE: image_tag_mutability (IMMUTABLE), scan_on_push (true), and encryption_type
# (KMS) are intentionally hardcoded as literals in main.tf — they are security
# invariants that must not be overridable per-environment, and literals let static
# analyzers (semgrep/checkov) verify them. Hence no variables for them here.

variable "force_delete" {
  type        = bool
  description = "Allow Terraform to delete repositories that still contain images. Set true so encryption/config changes that force repo replacement can proceed; images are rebuilt and repushed via build_and_push.sh after apply."
  default     = true
}

variable "untagged_expiry_days" {
  type        = number
  description = "Expire untagged images after this many days (0 disables the lifecycle policy)"
  default     = 14
}
