# =============================================================================
# Provider + version constraints.
#
# The aws_bedrockagentcore_agent_runtime resource requires the AWS provider 6.x
# line — do not downgrade below ~> 6.50 or the resource will not exist.
# =============================================================================

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.50"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  # Remote state backend — supply values at init time:
  #   terraform init \
  #     -backend-config="bucket=<your-tfstate-bucket>" \
  #     -backend-config="key=agentcore-s3files/terraform.tfstate" \
  #     -backend-config="region=ap-southeast-1"
  backend "s3" {
    encrypt                = true
    skip_region_validation = true
    use_lockfile           = true
  }
}

provider "aws" {
  region                 = var.aws_region
  skip_region_validation = true
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# Replica-region provider for S3 cross-region replication (checkov CKV_AWS_144).
provider "aws" {
  alias                  = "replica"
  region                 = var.replica_region
  skip_region_validation = true
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
