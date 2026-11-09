# =============================================================================
# MCP module — the two MCP servers plus shared networking and three least-
# privilege execution roles (agents, workspace MCP, and GitLab MCP).
#
#   MCP servers (mount S3 Files, protocol=MCP): workspace, gitlab
#
# This module owns the security group and runtime IAM roles because they must
# exist before the gateway and agents. Keeping them here makes the dependency
# one-directional and cycle-free:
#
#   mcp  ->  gateway  ->  agentcore(agents)
#
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- Security group: NFS (2049) self + HTTPS/DNS egress -----------------------
# This SG is attached to the AgentCore runtimes via
# network_configuration.network_mode_config.security_groups below. Checkov does
# not yet model aws_bedrockagentcore_agent_runtime as an attachment target.
resource "aws_security_group" "agentcore" {
  #checkov:skip=CKV2_AWS_5:Attached to AgentCore runtimes and S3 Files mount targets; Checkov does not model these resource types.
  name_prefix = "${var.project_name}-${var.environment}-agentcore-"
  description = "AgentCore runtimes (MCP + agents) and S3 Files mount targets"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "nfs_egress" {
  type              = "egress"
  description       = "NFS to S3 Files mount target"
  from_port         = 2049
  to_port           = 2049
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.agentcore.id
}

resource "aws_security_group_rule" "nfs_ingress" {
  type              = "ingress"
  description       = "NFS from AgentCore runtimes"
  from_port         = 2049
  to_port           = 2049
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.agentcore.id
}

resource "aws_security_group_rule" "https_egress" {
  type              = "egress"
  description       = "HTTPS to ECR, Bedrock, and other AWS APIs"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.agentcore.id
}

resource "aws_security_group_rule" "dns_tcp_egress" {
  type              = "egress"
  description       = "DNS resolution (TCP)"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.agentcore.id
}

resource "aws_security_group_rule" "dns_udp_egress" {
  type              = "egress"
  description       = "DNS resolution (UDP)"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.agentcore.id
}

# --- Least-privilege execution roles -----------------------------------------
locals {
  name_prefix    = "${var.project_name}-${var.environment}"
  runtime_prefix = replace(local.name_prefix, "-", "_")
  file_system_arns = {
    for key, arn in var.access_point_arns :
    key => replace(arn, "/\\/access-point\\/.*$/", "")
  }

  runtime_roles = {
    agent = {
      role_name = "${local.name_prefix}-agent-runtime"
      ecr_resources = [
        "arn:aws:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/${local.name_prefix}-analyzer-agent",
        "arn:aws:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/${local.name_prefix}-reviewer-agent",
      ]
      log_group_patterns = [
        "/aws/bedrock-agentcore/runtimes/${local.runtime_prefix}_analyzer-*",
        "/aws/bedrock-agentcore/runtimes/${local.runtime_prefix}_reviewer-*",
      ]
    }
    workspace = {
      role_name = "${local.name_prefix}-workspace-mcp-runtime"
      ecr_resources = [
        "arn:aws:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/${local.name_prefix}-workspace-mcp",
      ]
      log_group_patterns = [
        "/aws/bedrock-agentcore/runtimes/${local.runtime_prefix}_workspace_mcp-*",
      ]
    }
    gitlab = {
      role_name = "${local.name_prefix}-gitlab-mcp-runtime"
      ecr_resources = [
        "arn:aws:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/${local.name_prefix}-gitlab-mcp",
      ]
      log_group_patterns = [
        "/aws/bedrock-agentcore/runtimes/${local.runtime_prefix}_gitlab_mcp-*",
      ]
    }
  }

  common_runtime_statements = {
    for role_key, role in local.runtime_roles : role_key => [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "EcrPull"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = role.ecr_resources
      },
      {
        Sid    = "RuntimeLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = flatten([
          for group in role.log_group_patterns : [
            "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${group}",
          ]
        ])
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = "*"
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "bedrock-agentcore"
          }
        }
      },
    ]
  }

  s3files_statements = {
    for role_key in ["workspace", "gitlab"] : role_key => [
      {
        Sid      = "S3FilesClientAccess"
        Effect   = "Allow"
        Action   = ["s3files:ClientMount", "s3files:ClientWrite"]
        Resource = local.file_system_arns[role_key]
        Condition = {
          ArnEquals = {
            "s3files:AccessPointArn" = var.access_point_arns[role_key]
          }
        }
      },
      {
        Sid      = "S3FilesGetAccessPoint"
        Effect   = "Allow"
        Action   = ["s3files:GetAccessPoint"]
        Resource = var.access_point_arns[role_key]
      },
      {
        Sid      = "S3FilesListMountTargets"
        Effect   = "Allow"
        Action   = ["s3files:ListMountTargets"]
        Resource = local.file_system_arns[role_key]
      },
    ]
  }

  agent_statements = [
    {
      Sid    = "BedrockInvoke"
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      Resource = [
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-5-*",
        "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/${var.prompt_model_id}",
      ]
    },
    {
      Sid      = "InvokeReviewerRuntime"
      Effect   = "Allow"
      Action   = ["bedrock-agentcore:InvokeAgentRuntime"]
      Resource = "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:runtime/${local.runtime_prefix}_reviewer-*"
    },
    {
      Sid      = "InvokeGateway"
      Effect   = "Allow"
      Action   = ["bedrock-agentcore:InvokeGateway"]
      Resource = "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:gateway/${local.name_prefix}-gateway-*"
    },
  ]

  gitlab_statements = [
    {
      Sid      = "GitLabSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.gitlab_secret_arn
    },
    {
      Sid      = "GitLabSecretKmsDecrypt"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = var.gitlab_kms_key_arn
      Condition = {
        StringEquals = {
          "kms:ViaService" = "secretsmanager.${data.aws_region.current.region}.amazonaws.com"
        }
      }
    },
  ]
}

resource "aws_iam_role" "runtime" {
  for_each = local.runtime_roles

  name = each.value.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "runtime" {
  for_each = local.runtime_roles

  name = "${each.key}-runtime-access"
  role = aws_iam_role.runtime[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      local.common_runtime_statements[each.key],
      lookup(local.s3files_statements, each.key, []),
      [for statement in local.agent_statements : statement if each.key == "agent"],
      [for statement in local.gitlab_statements : statement if each.key == "gitlab"],
    )
  })
}

# AgentCore validates execution-role permissions synchronously when a runtime
# is created or updated. Give newly-created inline policies time to propagate
# before submitting either MCP or agent runtime changes.
resource "time_sleep" "wait_for_runtime_iam" {
  depends_on      = [aws_iam_role_policy.runtime]
  create_duration = "30s"

  # Re-run the propagation delay whenever any inline runtime policy changes.
  # AgentCore validates role permissions synchronously during runtime updates.
  triggers = {
    runtime_policies = sha256(jsonencode({
      for key, policy in aws_iam_role_policy.runtime : key => policy.policy
    }))
  }
}

# =============================================================================
# MCP SERVERS — mount S3 Files, speak MCP. (workspace, gitlab)
# =============================================================================
resource "aws_bedrockagentcore_agent_runtime" "mcp" {
  for_each = var.create_runtimes ? var.mcp_servers : {}

  agent_runtime_name = replace("${var.project_name}_${var.environment}_${each.key}_mcp", "-", "_")
  description        = each.value.description
  role_arn           = aws_iam_role.runtime[each.key].arn
  depends_on         = [time_sleep.wait_for_runtime_iam]

  agent_runtime_artifact {
    container_configuration {
      container_uri = coalesce(
        each.value.container_uri,
        try("${var.ecr_repository_urls["${each.key}-mcp"]}:${var.image_tag}", ""),
      )
    }
  }

  network_configuration {
    network_mode = "VPC"
    network_mode_config {
      subnets         = var.private_subnet_ids
      security_groups = [aws_security_group.agentcore.id]
    }
  }

  # Each MCP server mounts only its dedicated S3 Files access point.
  filesystem_configuration {
    s3_files_access_point {
      access_point_arn = var.access_point_arns[each.key]
      mount_path       = var.access_point_mount_paths[each.key]
    }
  }

  protocol_configuration {
    server_protocol = "MCP"
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = var.idle_runtime_session_timeout
    max_lifetime                 = var.max_lifetime
  }

  environment_variables = merge(
    {
      S3_MOUNT_PATH      = var.mount_path
      AWS_DEFAULT_REGION = data.aws_region.current.region
      AWS_REGION         = data.aws_region.current.region
    },
    each.key == "gitlab" && var.gitlab_secret_arn != "" ? { GITLAB_SECRET_ARN = var.gitlab_secret_arn } : {},
  )

  tags = { Component = "mcp-server", Server = each.key }
}

# AgentCore creates runtime log groups on first use. Configure each group
# idempotently after the runtime ID is known so both fresh and existing
# deployments receive the dedicated KMS key and an explicit retention period.
resource "null_resource" "runtime_log_encryption" {
  for_each = aws_bedrockagentcore_agent_runtime.mcp

  triggers = {
    log_group_name = "/aws/bedrock-agentcore/runtimes/${each.value.agent_runtime_id}-DEFAULT"
    kms_key_arn    = var.runtime_logs_kms_key_arn
    retention_days = tostring(var.runtime_log_retention_days)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      REGION="${data.aws_region.current.region}"
      LOG_GROUP="${self.triggers.log_group_name}"
      KMS_KEY_ARN="${self.triggers.kms_key_arn}"
      EXISTS=$(aws logs describe-log-groups --region "$REGION" \
        --log-group-name-prefix "$LOG_GROUP" \
        --query "length(logGroups[?logGroupName=='$LOG_GROUP'])" --output text)
      if [ "$EXISTS" = "0" ]; then
        aws logs create-log-group --region "$REGION" --log-group-name "$LOG_GROUP" \
          --kms-key-id "$KMS_KEY_ARN" \
          --tags Project="${var.project_name}" Environment="${var.environment}" ManagedBy="Terraform"
      else
        aws logs associate-kms-key --region "$REGION" --log-group-name "$LOG_GROUP" \
          --kms-key-id "$KMS_KEY_ARN"
      fi
      aws logs put-retention-policy --region "$REGION" --log-group-name "$LOG_GROUP" \
        --retention-in-days "${var.runtime_log_retention_days}"
    EOT
  }
}
