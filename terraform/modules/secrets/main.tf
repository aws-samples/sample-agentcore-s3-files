# =============================================================================
# Secrets module — creates the GitLab token secret in AWS Secrets Manager.
#
# The secret is ALWAYS created so the gitlab MCP has a stable GITLAB_SECRET_ARN to
# read. It is created with an empty value by default; set a real token via
# TF_VAR_gitlab_token, an untracked *.auto.tfvars, or by
# editing the secret directly in the AWS console (no re-apply needed for the latter).
#
# The gitlab MCP server accepts either a raw token string OR a JSON blob with a
# "token" key (see src/mcp-servers/gitlab/server.py::_get_token). We store JSON.
#
# SECURITY: never commit a real token. config.yaml/terraform.tfvars hold NO token.
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  gitlab_secret_name = "${var.project_name}-${var.environment}-gitlab-token"
}

# Customer-managed KMS key encrypting the GitLab token secret (checkov CKV_AWS_149 /
# semgrep aws-secretsmanager-secret-unencrypted). Key policy trusts the account root
# (for IAM-based access) and the Secrets Manager service. The MCP runtime receives a
# separate, key-scoped kms:Decrypt grant restricted to calls through Secrets Manager.
resource "aws_kms_key" "gitlab" {
  description             = "Encrypt the GitLab MCP token secret (${var.project_name}-${var.environment})"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowSecretsManagerUse"
        Effect    = "Allow"
        Principal = { Service = "secretsmanager.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant",
        ]
        Resource = "*"
      },
    ]
  })

  tags = {
    Component = "secrets"
    Purpose   = "gitlab-mcp-token-kms"
  }
}

resource "aws_kms_alias" "gitlab" {
  name          = "alias/${var.project_name}-${var.environment}-gitlab-token"
  target_key_id = aws_kms_key.gitlab.key_id
}

resource "aws_secretsmanager_secret" "gitlab" {
  #checkov:skip=CKV2_AWS_57:GitLab PAT rotation is controlled by GitLab; Secrets Manager cannot natively generate or rotate this third-party credential.
  name                    = local.gitlab_secret_name
  description             = "GitLab access token for the gitlab MCP server (${var.project_name}-${var.environment})"
  recovery_window_in_days = var.recovery_window_in_days
  kms_key_id              = aws_kms_key.gitlab.arn

  tags = {
    Component = "secrets"
    Purpose   = "gitlab-mcp-token"
  }
}

# checkov CKV2_AWS_57 (automatic rotation) is NOT APPLICABLE: this secret stores a
# user-supplied GitLab Personal Access Token, not an AWS-generated credential.
# Secrets Manager rotation requires a rotation Lambda that can mint a new credential;
# AWS cannot auto-rotate a third-party GitLab token. Rotation is a manual GitLab +
# console action. The secret is KMS-encrypted (CMK above) and access is scoped.
resource "aws_secretsmanager_secret_version" "gitlab" {
  secret_id     = aws_secretsmanager_secret.gitlab.id
  secret_string = jsonencode({ token = var.gitlab_token })

  # Let a user rotate the token in the console without Terraform reverting it on the
  # next apply. Remove this block if you'd rather TF always own the value.
  lifecycle {
    ignore_changes = [secret_string]
  }
}
