# =============================================================================
# AgentCore Gateway — governed MCP tool surface for the agents.
#
# The agents reach the workspace + gitlab MCP servers THROUGH this gateway
# (not by invoking the MCP runtimes directly). The gateway:
#   * speaks MCP (protocol_type = "MCP"), SigV4 inbound auth (AWS_IAM),
#   * authenticates to the MCP runtimes with its own service role (SigV4,
#     service = "bedrock-agentcore"),
#   * aggregates both MCP servers into one endpoint (GATEWAY_URL) that the
#     agents call via shared/gateway_tools.py.
#
# The two MCP-runtime targets use target_configuration.mcp.mcp_server.endpoint,
# which is the runtime invocation URL.
#
# Everything is gated on var.create_gateway (a PLAN-TIME flag) because the
# targets reference the MCP runtime ARNs (apply-time values) — count/for_each
# keys must be plan-time known, exactly like the runtimes themselves.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  gateway_name = "${var.project_name}-${var.environment}-gateway"
  region       = data.aws_region.current.region

  # Runtime invocation URL each MCP target points at.
  workspace_endpoint = var.workspace_mcp_runtime_arn != "" ? "https://bedrock-agentcore.${local.region}.amazonaws.com/runtimes/${urlencode(var.workspace_mcp_runtime_arn)}/invocations/" : ""
  gitlab_endpoint    = var.gitlab_mcp_runtime_arn != "" ? "https://bedrock-agentcore.${local.region}.amazonaws.com/runtimes/${urlencode(var.gitlab_mcp_runtime_arn)}/invocations/" : ""
}

# ─── Gateway ──────────────────────────────────────────────────────────────────
resource "aws_bedrockagentcore_gateway" "this" {
  count = var.create_gateway ? 1 : 0

  name            = local.gateway_name
  description     = "MCP tool gateway — workspace + gitlab MCP servers for the review agents"
  protocol_type   = "MCP"
  authorizer_type = "AWS_IAM"
  role_arn        = aws_iam_role.gateway[0].arn

  protocol_configuration {
    mcp {
      session_configuration {
        session_timeout_in_seconds = var.session_timeout_in_seconds
      }
    }
  }
}

# ─── Gateway service role ──────────────────────────────────────────────────────
resource "aws_iam_role" "gateway" {
  count = var.create_gateway ? 1 : 0

  name = "${local.gateway_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

# The gateway invokes the MCP runtimes with SigV4 — grant InvokeAgentRuntime on them.
resource "aws_iam_role_policy" "gateway_invoke_mcp_runtimes" {
  count = var.create_gateway ? 1 : 0

  name = "invoke-mcp-runtime-targets"
  role = aws_iam_role.gateway[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock-agentcore:InvokeAgentRuntime"]
      Resource = compact([
        var.workspace_mcp_runtime_arn,
        var.workspace_mcp_runtime_arn != "" ? "${var.workspace_mcp_runtime_arn}/*" : "",
        var.gitlab_mcp_runtime_arn,
        var.gitlab_mcp_runtime_arn != "" ? "${var.gitlab_mcp_runtime_arn}/*" : "",
      ])
    }]
  })
}

# AgentCore validates the gateway's invoke permissions synchronously when a
# target is created — wait for the IAM policy to propagate first.
resource "time_sleep" "wait_for_gateway_iam" {
  count           = var.create_gateway ? 1 : 0
  depends_on      = [aws_iam_role_policy.gateway_invoke_mcp_runtimes]
  create_duration = "30s"
}

# ─── Target: workspace MCP ─────────────────────────────────────────────────────
resource "aws_bedrockagentcore_gateway_target" "workspace_mcp" {
  count = var.create_gateway ? 1 : 0

  name               = "workspace-tools"
  gateway_identifier = aws_bedrockagentcore_gateway.this[0].gateway_id
  description        = "Workspace MCP — reviews/ + plans/ artifacts on shared storage"
  depends_on         = [time_sleep.wait_for_gateway_iam]

  credential_provider_configuration {
    gateway_iam_role {
      service = "bedrock-agentcore"
    }
  }

  target_configuration {
    mcp {
      mcp_server {
        endpoint = local.workspace_endpoint
      }
    }
  }
}

# ─── Target: gitlab MCP ────────────────────────────────────────────────────────
resource "aws_bedrockagentcore_gateway_target" "gitlab_mcp" {
  count = var.create_gateway ? 1 : 0

  name               = "gitlab-tools"
  gateway_identifier = aws_bedrockagentcore_gateway.this[0].gateway_id
  description        = "GitLab MCP — read-only clone + fetch MR/diff + comment/inline"
  depends_on         = [time_sleep.wait_for_gateway_iam]

  credential_provider_configuration {
    gateway_iam_role {
      service = "bedrock-agentcore"
    }
  }

  target_configuration {
    mcp {
      mcp_server {
        endpoint = local.gitlab_endpoint
      }
    }
  }
}
