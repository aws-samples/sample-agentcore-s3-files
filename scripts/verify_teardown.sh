#!/bin/bash
###############################################################################
# verify_teardown.sh — confirm no cost-bearing resources from this stack remain.
#
# Run after teardown.sh. Reports (does NOT delete) any lingering S3 Files
# filesystems, ECR repos, NAT gateways, AgentCore runtimes, or workspace bucket.
# Useful for catching an orphaned VPC from an earlier failed apply (which
# terraform destroy would not have touched, since it was never in state).
#
# USAGE
#   export AWS_PROFILE=<the-profile-you-deployed-with>
#   ./scripts/verify_teardown.sh
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

REGION="$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_region 2>/dev/null || true)"
if [ -z "$REGION" ] || [ "$REGION" = "null" ]; then
  REGION="$(awk -F'"' '/^[[:space:]]*aws_region[[:space:]]*=/{print $2; exit}' "$TERRAFORM_DIR/environments/dev/terraform.tfvars" 2>/dev/null || true)"
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-${AWS_REGION:-}}}"
if [ -z "$REGION" ]; then
  echo "ERROR: could not resolve AWS Region from Terraform, tfvars, or the environment." >&2
  exit 1
fi

# ─── Derive resource name prefixes from Terraform (NO hardcoded names) ───────
TFVARS="$TERRAFORM_DIR/environments/dev/terraform.tfvars"
PROJECT_NAME="$(terraform -chdir="$TERRAFORM_DIR" output -raw project_name 2>/dev/null || true)"
if [ -z "$PROJECT_NAME" ] || [ "$PROJECT_NAME" = "null" ]; then
  PROJECT_NAME="$(awk -F'"' '/^[[:space:]]*project_name[[:space:]]*=/{print $2; exit}' "$TFVARS" 2>/dev/null || true)"
fi
ENVIRONMENT="$(terraform -chdir="$TERRAFORM_DIR" output -raw environment 2>/dev/null || true)"
if [ -z "$ENVIRONMENT" ] || [ "$ENVIRONMENT" = "null" ]; then
  ENVIRONMENT="$(awk -F'"' '/^[[:space:]]*environment[[:space:]]*=/{print $2; exit}' "$TFVARS" 2>/dev/null || true)"
fi
if [ -z "$PROJECT_NAME" ] || [ -z "$ENVIRONMENT" ]; then
  echo "ERROR: could not resolve project_name/environment from terraform output or $TFVARS." >&2
  exit 1
fi
PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"                 # bucket / ECR / IAM / VPC tags
RUNTIME_PREFIX="$(echo "$PREFIX" | tr '-' '_')"          # AgentCore runtime names (underscores)

echo "== Verifying teardown in region $REGION (account $(aws sts get-caller-identity --query Account --output text 2>/dev/null)) =="
echo "   Resource prefix: $PREFIX"
CLEAN=true

check() { # label, value
  if [ -z "$2" ] || [ "$2" = "None" ] || [ "$2" = "[]" ]; then
    echo "  [clean] $1"
  else
    echo "  [LEFT]  $1: $2"; CLEAN=false
  fi
}

check "S3 Files filesystems" "$(aws s3files list-file-systems --region "$REGION" \
  --query "fileSystems[?contains(bucket,'${PREFIX}')].fileSystemId" --output text 2>/dev/null)"

check "ECR repositories" "$(aws ecr describe-repositories --region "$REGION" \
  --query "repositories[?starts_with(repositoryName,'${PREFIX}')].repositoryName" --output text 2>/dev/null)"

check "AgentCore runtimes" "$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimes[?starts_with(agentRuntimeName,'${RUNTIME_PREFIX}')].agentRuntimeName" --output text 2>/dev/null)"

check "NAT gateways (available)" "$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=state,Values=available" \
  --query "NatGateways[?Tags[?contains(Value,'${PREFIX}')]].NatGatewayId" --output text 2>/dev/null)"

check "VPCs" "$(aws ec2 describe-vpcs --region "$REGION" \
  --query "Vpcs[?Tags[?contains(Value,'${PREFIX}')]].VpcId" --output text 2>/dev/null)"

BUCKET="$(terraform -chdir="$TERRAFORM_DIR" output -raw workspace_bucket_name 2>/dev/null || true)"
if [ -n "$BUCKET" ] && [ "$BUCKET" != "null" ]; then
  if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
    echo "  [LEFT]  workspace bucket: $BUCKET"; CLEAN=false
  else
    echo "  [clean] workspace bucket"
  fi
fi

echo ""
if $CLEAN; then
  echo "All clear — no lingering resources from this stack."
else
  echo "Some resources remain (see [LEFT] above). If a VPC lingers it is likely an"
  echo "orphan from an earlier failed apply; delete its NAT gateways + subnets + VPC by hand."
fi
