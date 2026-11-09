# =============================================================================
# AgentCore (agents) module — the two A2A agents.
#
#   Agents (A2A, no S3 mount): analyzer -> reviewer (A2A handoff)
#
# Agents reach shared storage ONLY through the MCP servers, which they call via
# the AgentCore Gateway (GATEWAY_URL). They run in the shared SG and assume the
# agent-only runtime role — both owned by the mcp module and passed here, so the
# dependency is one-directional and cycle-free:
#
#   mcp  ->  gateway  ->  agentcore(agents)
#
# A2A: the analyzer invokes the reviewer directly, so it needs the
# reviewer's runtime id. That is why the two are separate resources (a for_each
# self-reference would be a cycle): the reviewer is created first, then the
# analyzer references it.
# =============================================================================

locals {
  agent_common_env = {
    # MCP is reached through the Gateway; keep the raw runtime ids too for reference.
    GATEWAY_URL              = var.gateway_url
    WORKSPACE_MCP_RUNTIME_ID = lookup(var.mcp_runtime_ids, "workspace", "")
    GITLAB_MCP_RUNTIME_ID    = lookup(var.mcp_runtime_ids, "gitlab", "")
    BEDROCK_MODEL_ID         = var.prompt_model_id
    AWS_DEFAULT_REGION       = data.aws_region.current.region
    AWS_REGION               = data.aws_region.current.region
  }
  create_agents = var.create_runtimes && length(var.agents) > 0
  runtime_log_groups = merge(
    local.create_agents && contains(keys(var.agents), "reviewer") ? {
      reviewer = "/aws/bedrock-agentcore/runtimes/${aws_bedrockagentcore_agent_runtime.reviewer[0].agent_runtime_id}-DEFAULT"
    } : {},
    local.create_agents && contains(keys(var.agents), "analyzer") ? {
      analyzer = "/aws/bedrock-agentcore/runtimes/${aws_bedrockagentcore_agent_runtime.analyzer[0].agent_runtime_id}-DEFAULT"
    } : {},
  )
}

data "aws_region" "current" {}

# --- Reviewer (finalizer) — created first (end of the A2A chain); posts to GitLab -
resource "aws_bedrockagentcore_agent_runtime" "reviewer" {
  count = local.create_agents && contains(keys(var.agents), "reviewer") ? 1 : 0

  agent_runtime_name = replace("${var.project_name}_${var.environment}_reviewer", "-", "_")
  description        = var.agents["reviewer"].description
  role_arn           = var.runtime_role_arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = coalesce(
        var.agents["reviewer"].container_uri,
        try("${var.ecr_repository_urls["reviewer-agent"]}:${var.image_tag}", ""),
      )
    }
  }

  network_configuration {
    network_mode = "VPC"
    network_mode_config {
      subnets         = var.private_subnet_ids
      security_groups = [var.security_group_id]
    }
  }

  protocol_configuration {
    server_protocol = "A2A"
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = var.idle_runtime_session_timeout
    max_lifetime                 = var.max_lifetime
  }

  environment_variables = merge(local.agent_common_env, { AGENT_ROLE = "reviewer" })

  tags = { Component = "agent", Agent = "reviewer" }
}

# --- Analyzer (tech + security) — depends on the reviewer so it can hand off via A2A
resource "aws_bedrockagentcore_agent_runtime" "analyzer" {
  count = local.create_agents && contains(keys(var.agents), "analyzer") ? 1 : 0

  agent_runtime_name = replace("${var.project_name}_${var.environment}_analyzer", "-", "_")
  description        = var.agents["analyzer"].description
  role_arn           = var.runtime_role_arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = coalesce(
        var.agents["analyzer"].container_uri,
        try("${var.ecr_repository_urls["analyzer-agent"]}:${var.image_tag}", ""),
      )
    }
  }

  network_configuration {
    network_mode = "VPC"
    network_mode_config {
      subnets         = var.private_subnet_ids
      security_groups = [var.security_group_id]
    }
  }

  protocol_configuration {
    server_protocol = "A2A"
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = var.idle_runtime_session_timeout
    max_lifetime                 = var.max_lifetime
  }

  # The analyzer calls the reviewer directly over A2A — inject its runtime id.
  environment_variables = merge(local.agent_common_env, {
    AGENT_ROLE          = "analyzer"
    REVIEWER_RUNTIME_ID = try(aws_bedrockagentcore_agent_runtime.reviewer[0].agent_runtime_id, "")
  })

  tags = { Component = "agent", Agent = "analyzer" }

  lifecycle {
    precondition {
      condition     = var.vpc_id != "" && length(var.private_subnet_ids) > 0
      error_message = "AgentCore VPC runtime requires vpc_id and at least one private subnet."
    }
  }
}

# AgentCore creates runtime log groups on first use. Configure each group after
# its generated runtime ID is known, while remaining idempotent for existing
# deployments where the group already exists.
resource "null_resource" "runtime_log_encryption" {
  for_each = local.runtime_log_groups

  triggers = {
    log_group_name = each.value
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
