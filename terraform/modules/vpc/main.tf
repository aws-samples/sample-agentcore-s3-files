# =============================================================================
# VPC module — creates a VPC with public + private subnets, IGW, and NAT.
# Required because S3 Files is only reachable over NFS via mount targets that
# live inside VPC subnets.
# =============================================================================

locals {
  availability_zone_names = lookup(var.vpc_config, "availability_zone_names", [])
  availability_zone_count = lookup(var.vpc_config, "availability_zone_count", 2)
}

resource "aws_vpc" "main" {
  cidr_block           = lookup(var.vpc_config, "cidr_block", "10.0.0.0/16")
  enable_dns_hostnames = lookup(var.vpc_config, "enable_dns_hostnames", true)
  enable_dns_support   = lookup(var.vpc_config, "enable_dns_support", true)
  tags = {
    Name = "${var.application_name}-${var.environment}-vpc"
  }

  lifecycle {
    precondition {
      condition     = length(local.availability_zone_names) >= local.availability_zone_count
      error_message = "vpc.availability_zone_names must contain at least availability_zone_count fixed zone names."
    }
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.application_name}-${var.environment}-igw"
  }
}

resource "aws_subnet" "public" {
  count             = local.availability_zone_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(lookup(var.vpc_config, "cidr_block", "10.0.0.0/16"), 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  # During first provision set to true, then flip to false post-creation.
  map_public_ip_on_launch = false
  tags = {
    Name = "${var.application_name}-${var.environment}-public-subnet-${count.index + 1}"
    Type = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = {
    Name = "${var.application_name}-${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private subnets — where S3 Files mount targets and AgentCore runtimes live.
resource "aws_subnet" "private" {
  count             = local.availability_zone_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(lookup(var.vpc_config, "cidr_block", "10.0.0.0/16"), 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "${var.application_name}-${var.environment}-private-subnet-${count.index + 1}"
    Type = "private"
  }
}

# NAT gateways — let private subnets reach the internet (ECR pulls, AWS APIs).
resource "aws_eip" "nat" {
  count      = lookup(var.vpc_config, "enable_nat_gateway", true) ? local.availability_zone_count : 0
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags = {
    Name = "${var.application_name}-${var.environment}-nat-eip-${count.index + 1}"
  }
}

resource "aws_nat_gateway" "main" {
  count         = lookup(var.vpc_config, "enable_nat_gateway", true) ? local.availability_zone_count : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags = {
    Name = "${var.application_name}-${var.environment}-nat-${count.index + 1}"
  }
  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  count  = local.availability_zone_count
  vpc_id = aws_vpc.main.id
  dynamic "route" {
    for_each = length(aws_nat_gateway.main) > 0 ? [aws_nat_gateway.main[count.index].id] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = route.value
    }
  }
  tags = {
    Name = "${var.application_name}-${var.environment}-private-rt-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

data "aws_availability_zones" "available" {
  state = "available"

  # Allowlist fixed zone identities so the result set cannot silently expand
  # when AWS adds an Availability Zone (checkov CKV_AWS_394).
  filter {
    name   = "zone-name"
    values = local.availability_zone_names
  }
}

# =============================================================================
# Security hardening
# =============================================================================

# Lock down the VPC's auto-created default security group: allow no ingress or
# egress. Workloads use the dedicated agentcore SG, so this stays unused and
# deny-all. (checkov CKV2_AWS_12)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.application_name}-${var.environment}-default-sg-locked"
  }
  # No ingress/egress rules => deny all.
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# KMS CMK to encrypt the flow-logs log group at rest (kics
# "CloudWatch Log Group Without KMS"). The key policy grants the CloudWatch Logs
# service in this region permission to use the key for the log group.
resource "aws_kms_key" "flow_logs" {
  description             = "Encrypt VPC flow-log CloudWatch group for ${var.application_name}-${var.environment}"
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
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/vpc/flow-logs/${var.application_name}-${var.environment}"
          }
        }
      },
    ]
  })

  tags = {
    Name = "${var.application_name}-${var.environment}-vpc-flow-logs-kms"
  }
}

# --- VPC Flow Logs -> CloudWatch Logs (checkov CKV2_AWS_11) -------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/flow-logs/${var.application_name}-${var.environment}"
  retention_in_days = lookup(var.vpc_config, "flow_log_retention_days", 365)
  kms_key_id        = aws_kms_key.flow_logs.arn
  tags = {
    Name = "${var.application_name}-${var.environment}-vpc-flow-logs"
  }
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.application_name}-${var.environment}-vpc-flow-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "vpc-flow-logs-to-cloudwatch"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 600
  tags = {
    Name = "${var.application_name}-${var.environment}-vpc-flow-log"
  }
}
