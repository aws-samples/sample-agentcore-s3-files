# =============================================================================
# Root module — loads environment config from config.yaml and wires the
# vpc, ecr, s3files, secrets, mcp, gateway, and agentcore modules together.
#
# Module topology (one-directional, cycle-free):
#   ecr ─┐
#   vpc ─┼─> mcp (SG + scoped roles + MCP runtimes) ─> gateway ─> agentcore (agents)
#   s3files (bucket/fs/access point) ─┘        (targets MCP)      (GATEWAY_URL)
#
# Two-phase deploy — the runtimes reference container images that must be built
# and pushed BEFORE the runtimes are created:
#   Phase 1: create_runtimes = false -> VPC + ECR + S3 Files + SG + IAM
#            (then run scripts/build_and_push.sh to push the images)
#   Phase 2: create_runtimes = true  -> MCP runtimes + gateway + agent runtimes
#
# S3 Files is created in a single apply: the access point ARNs are apply-time
# value resolved within that apply (null_resource -> data.external in modules/s3files).
# =============================================================================

locals {
  env_vars = yamldecode(file("${path.module}/environments/${var.environment}/config.yaml"))

  vpc_config       = lookup(local.env_vars, "vpc", {})
  s3files_config   = lookup(local.env_vars, "s3files", {})
  agentcore_config = lookup(local.env_vars, "agentcore", {})
  secrets_config   = lookup(local.env_vars, "secrets", {})

  # GitLab secret ARN wired into the gitlab MCP runtime. The secrets module ALWAYS
  # creates this secret (empty until the user supplies a token out-of-band).
  gitlab_secret_arn = module.secrets.gitlab_secret_arn

  # Two-phase deploy gate — because ECR images must exist before the runtimes
  # reference them. Plan-time flag from config.yaml (agentcore.create_runtimes).
  # The gateway + its MCP-runtime targets are created in the same phase as the
  # runtimes (they reference the MCP runtime ARNs), so they share the flag.
  create_runtimes = lookup(local.agentcore_config, "create_runtimes", false)

  # ECR repo names are DERIVED from the agentcore config (no separate ecr block):
  #   each agent key      -> "<key>-agent"   (e.g. analyzer-agent, reviewer-agent)
  #   each mcp_server key  -> "<key>-mcp"     (e.g. workspace-mcp, gitlab-mcp)
  ecr_repository_names = concat(
    [for k in keys(lookup(local.agentcore_config, "agents", {})) : "${k}-agent"],
    [for k in keys(lookup(local.agentcore_config, "mcp_servers", {})) : "${k}-mcp"],
  )
  log_level = coalesce(var.log_level, lookup(local.env_vars, "log_level", null), "INFO")

  # Unified VPC resolution: use module outputs when we create the VPC,
  # otherwise fall back to the existing IDs from config.yaml.
  effective_vpc_id             = lookup(local.vpc_config, "create_vpc", false) ? module.vpc[0].vpc_id : lookup(local.vpc_config, "id", "")
  effective_private_subnet_ids = lookup(local.vpc_config, "create_vpc", false) ? module.vpc[0].private_subnet_ids : lookup(local.vpc_config, "private_subnet_ids", [])
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Dedicated CMK for all AgentCore runtime CloudWatch log groups. The encryption
# context limits service use to this stack's runtime log-group namespace.
resource "aws_kms_key" "agentcore_runtime_logs" {
  description             = "Encrypt AgentCore runtime logs for ${var.project_name}-${var.environment}"
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
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.region}.amazonaws.com" }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/${replace("${var.project_name}-${var.environment}", "-", "_")}_*"
          }
        }
      },
    ]
  })

  tags = { Name = "${var.project_name}-${var.environment}-agentcore-runtime-logs" }
}

resource "aws_kms_alias" "agentcore_runtime_logs" {
  name          = "alias/${var.project_name}-${var.environment}-agentcore-runtime-logs"
  target_key_id = aws_kms_key.agentcore_runtime_logs.key_id
}

# ECR — repositories for the agent + MCP images. Created in PHASE 1 so images can
# be built and pushed BEFORE the Phase 2 runtimes reference them.
module "ecr" {
  source = "./modules/ecr"

  project_name     = var.project_name
  environment      = var.environment
  repository_names = local.ecr_repository_names
}

# VPC — conditionally create a new VPC or use an existing one from config.yaml.
module "vpc" {
  source = "./modules/vpc"
  count  = lookup(local.vpc_config, "create_vpc", false) ? 1 : 0

  application_name = var.project_name
  environment      = var.environment
  vpc_config       = local.vpc_config
}

# Secrets — GitLab token for the gitlab MCP server. Token VALUE supplied
# out-of-band (TF_VAR_gitlab_token), never committed.
module "secrets" {
  source = "./modules/secrets"

  project_name = var.project_name
  environment  = var.environment

  gitlab_token            = var.gitlab_token
  recovery_window_in_days = lookup(local.secrets_config, "recovery_window_in_days", 0)
}

# MCP — shared SG, separate least-privilege runtime roles, and two MCP server
# runtimes. The gateway targets the MCP runtimes and the agents use the agent-only
# role. Created in Phase 2 (needs pushed images).
module "mcp" {
  source = "./modules/mcp"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = local.effective_vpc_id
  private_subnet_ids = local.effective_private_subnet_ids

  access_point_arns = {
    workspace = module.s3files.access_point_arns["workspaces"]
    gitlab    = module.s3files.access_point_arns["repositories"]
  }
  access_point_mount_paths = {
    workspace = "${lookup(local.s3files_config, "mount_path", "/mnt")}/workspaces"
    gitlab    = "${lookup(local.s3files_config, "mount_path", "/mnt")}/repositories"
  }
  mount_path = lookup(local.s3files_config, "mount_path", "/mnt")

  mcp_servers     = lookup(local.agentcore_config, "mcp_servers", {})
  create_runtimes = local.create_runtimes

  ecr_repository_urls = module.ecr.repository_urls
  image_tag           = lookup(local.agentcore_config, "image_tag", "latest")

  gitlab_secret_arn  = local.gitlab_secret_arn
  gitlab_kms_key_arn = module.secrets.gitlab_kms_key_arn
  prompt_model_id    = lookup(local.agentcore_config, "model_id", "global.anthropic.claude-sonnet-4-5-20250929-v1:0")

  runtime_logs_kms_key_arn   = aws_kms_key.agentcore_runtime_logs.arn
  runtime_log_retention_days = lookup(local.agentcore_config, "runtime_log_retention_days", 365)

  idle_runtime_session_timeout = lookup(local.agentcore_config, "idle_runtime_session_timeout", 900)
  max_lifetime                 = lookup(local.agentcore_config, "max_lifetime", 28800)
}

# Gateway — MCP tool surface fronting the two MCP runtimes. Created in Phase 2
# (targets reference the MCP runtime ARNs). Agents call this via GATEWAY_URL.
module "gateway" {
  source = "./modules/gateway"

  project_name = var.project_name
  environment  = var.environment

  create_gateway            = local.create_runtimes
  workspace_mcp_runtime_arn = lookup(module.mcp.mcp_runtime_arns, "workspace", "")
  gitlab_mcp_runtime_arn    = lookup(module.mcp.mcp_runtime_arns, "gitlab", "")
}

# AgentCore (agents) — the two A2A agents. Run in the shared SG, assume the
# agent-only role from module.mcp, and reach MCP through the gateway.
module "agentcore" {
  source = "./modules/agentcore"

  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = local.effective_vpc_id
  private_subnet_ids = local.effective_private_subnet_ids

  security_group_id = module.mcp.security_group_id
  runtime_role_arn  = module.mcp.agent_runtime_role_arn
  mcp_runtime_ids   = module.mcp.mcp_runtime_ids
  gateway_url       = module.gateway.gateway_url

  runtime_logs_kms_key_arn   = aws_kms_key.agentcore_runtime_logs.arn
  runtime_log_retention_days = lookup(local.agentcore_config, "runtime_log_retention_days", 365)

  agents          = lookup(local.agentcore_config, "agents", {})
  create_runtimes = local.create_runtimes
  prompt_model_id = lookup(local.agentcore_config, "model_id", "global.anthropic.claude-sonnet-4-5-20250929-v1:0")

  ecr_repository_urls = module.ecr.repository_urls
  image_tag           = lookup(local.agentcore_config, "image_tag", "latest")

  idle_runtime_session_timeout = lookup(local.agentcore_config, "idle_runtime_session_timeout", 900)
  max_lifetime                 = lookup(local.agentcore_config, "max_lifetime", 28800)
}

# S3 Files — bucket + IAM role + filesystem + mount target(s) + access point.
# ALWAYS created (single apply). The mount targets use the mcp module's SG.
module "s3files" {
  source = "./modules/s3files"
  providers = {
    aws         = aws
    aws.replica = aws.replica
  }

  project_name      = var.project_name
  environment       = var.environment
  workspace_prefix  = lookup(local.s3files_config, "workspace_prefix", "agentcore/workspaces/")
  retention_days    = lookup(local.s3files_config, "retention_days", 30)
  create_s3files    = true
  vpc_subnet_ids    = local.effective_private_subnet_ids
  security_group_id = module.mcp.security_group_id
}
