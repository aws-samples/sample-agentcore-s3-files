# =============================================================================
# ECR module — one repository per container image (agents + MCP servers).
#
# Created in PHASE 1 so images can be built and pushed BEFORE the Phase 2
# runtimes (which reference the pushed image URIs) are created.
# =============================================================================

data "aws_caller_identity" "current" {}

# Customer-managed KMS key encrypting all ECR repositories at rest (checkov
# CKV_AWS_136 / semgrep). Rotation enabled; key policy trusts the account root and
# grants the ECR service encrypt/decrypt.
resource "aws_kms_key" "ecr" {
  description             = "Encrypt ECR repositories for ${var.project_name}-${var.environment}"
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
        Sid       = "AllowECRService"
        Effect    = "Allow"
        Principal = { Service = "ecr.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
      },
    ]
  })

  tags = { Component = "ecr", Purpose = "ecr-encryption-kms" }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.project_name}-${var.environment}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

# image_tag_mutability and scan_on_push are set as LITERALS (not variables) so static
# analyzers (semgrep) can verify the secure values. IMMUTABLE prevents tag overwrite;
# scan_on_push runs a vulnerability scan on every push. These security invariants are
# intentionally not overridable per-environment.
resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = "${var.project_name}-${var.environment}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = { Component = "ecr", Image = each.key }
}

# Optional lifecycle policy — expire untagged images after N days.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = var.untagged_expiry_days > 0 ? aws_ecr_repository.this : {}
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after ${var.untagged_expiry_days} days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = var.untagged_expiry_days
      }
      action = { type = "expire" }
    }]
  })
}
