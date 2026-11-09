#!/bin/bash
###############################################################################
# teardown.sh — CLI pre-cleanup before `terraform destroy`.
#
# WHY THIS SCRIPT EXISTS
#   Three things block a clean `terraform destroy` of this stack, and none of
#   them are handled by Terraform itself:
#
#   1. S3 Files filesystem + mount targets — created by a null_resource via the
#      AWS CLI (no native TF resource), so `terraform destroy` removes the
#      null_resource from STATE but leaves the real filesystem running. Worse,
#      while the filesystem is attached to the bucket you CANNOT:
#        - change bucket versioning  -> "BucketHasS3FileSystemAttached"
#        - delete the subnets / SG   -> mount-target ENIs cause DependencyViolation
#      So the S3 Files filesystem MUST be deleted FIRST.
#
#   2. ECR repositories still containing images -> "RepositoryNotEmptyException".
#
#   3. A versioned S3 bucket with objects -> bucket delete fails until emptied.
#
#   This script performs ONLY the CLI cleanup (steps 1-3). It does NOT run
#   terraform. After it finishes, run `terraform destroy` yourself:
#
#     cd terraform
#     terraform destroy -parallelism=1 -var-file=environments/dev/terraform.tfvars
#
# ORDER (each step unblocks the terraform destroy that follows):
#   1. Delete S3 Files access points -> mount targets -> filesystem (unblocks subnets/SG/bucket)
#   2. Empty the ECR repositories                          (unblocks ECR repo delete)
#   3. Empty the S3 workspace bucket (all versions)         (unblocks bucket delete)
#
# USAGE
#   export AWS_PROFILE=<the-profile-you-deployed-with>
#   ./scripts/teardown.sh [--yes]
#
#   --yes   skip the interactive confirmation
#
# Safe to re-run: every step is idempotent and tolerates already-deleted resources.
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

ASSUME_YES=false
[ "${1:-}" = "--yes" ] && ASSUME_YES=true

for cmd in aws python3; do
  command -v "$cmd" >/dev/null 2>&1 || { err "'$cmd' is required."; exit 1; }
done

# ─── Resolve region: prefer terraform output, then tfvars, then env ─────────
REGION="$(terraform -chdir="$TERRAFORM_DIR" output -raw aws_region 2>/dev/null || true)"
if [ -z "$REGION" ] || [ "$REGION" = "null" ]; then
  REGION="$(awk -F'"' '/^[[:space:]]*aws_region[[:space:]]*=/{print $2; exit}' "$TERRAFORM_DIR/environments/dev/terraform.tfvars" 2>/dev/null || true)"
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-${AWS_REGION:-}}}"
if [ -z "$REGION" ]; then
  err "Could not resolve AWS Region from Terraform, tfvars, or the environment."
  exit 1
fi
info "Region: $REGION"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '??')"
info "AWS account: $ACCOUNT"
if [ -z "${AWS_PROFILE:-}" ]; then
  warn "AWS_PROFILE is not set — using default credentials (account $ACCOUNT). If that is not"
  warn "the account you deployed into, Ctrl-C and 'export AWS_PROFILE=<profile>' first."
else
  info "Profile: $AWS_PROFILE"
fi

# ─── Derive resource name prefixes from Terraform (NO hardcoded names) ───────
# Prefer terraform outputs; fall back to parsing terraform.tfvars. Resource names
# are "<project_name>-<environment>-..."; AgentCore runtime names use underscores.
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
  err "Could not resolve project_name/environment from terraform output or $TFVARS."
  err "Cannot safely identify resources to clean up. Aborting."
  exit 1
fi
PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"                 # e.g. myapp-dev  (bucket/ECR/IAM/VPC)
info "Resource prefix: $PREFIX"

# ─── Resolve the workspace bucket name from output/state ─────────────────────
BUCKET="$(terraform -chdir="$TERRAFORM_DIR" output -raw workspace_bucket_name 2>/dev/null || true)"
if [ -z "$BUCKET" ] || [ "$BUCKET" = "null" ]; then
  # Fall back to reading the tfstate directly
  BUCKET="$(python3 - "$TERRAFORM_DIR/terraform.tfstate" <<'PY' 2>/dev/null || true
import json,sys
try:
    st=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for r in st.get("resources",[]):
    if r["type"]=="aws_s3_bucket":
        print(r["instances"][0]["attributes"]["bucket"]); break
PY
)"
fi
info "Workspace bucket: ${BUCKET:-<not found>}"

echo ""
warn "This will PERMANENTLY DELETE the S3 Files filesystem, all ECR images, and the"
warn "workspace bucket contents so that 'terraform destroy' can then remove the rest."
if ! $ASSUME_YES; then
  read -r -p "Type 'destroy' to continue: " CONFIRM
  [ "$CONFIRM" = "destroy" ] || { info "Aborted."; exit 0; }
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — Delete S3 Files mount targets + filesystem (the key unblocker)
# ═════════════════════════════════════════════════════════════════════════════
info "STEP 1: S3 Files teardown"
# Correct S3 Files delete order is: ACCESS POINTS -> MOUNT TARGETS -> FILESYSTEM.
# (delete-file-system fails with ConflictException while access points still exist,
#  and subnets/SG can't be deleted while mount-target ENIs are still attached.)
FS_ID=""
if [ -n "${BUCKET:-}" ]; then
  BUCKET_ARN="arn:aws:s3:::${BUCKET}"
  FS_ID=$(aws s3files list-file-systems --region "$REGION" \
    --query "fileSystems[?bucket=='$BUCKET_ARN'].fileSystemId | [0]" --output text 2>/dev/null || echo "")
fi
if [ -z "$FS_ID" ] || [ "$FS_ID" = "None" ] || [ "$FS_ID" = "null" ]; then
  warn "  No S3 Files filesystem found for bucket '${BUCKET:-?}' (already deleted?). Skipping."
else
  info "  Filesystem: $FS_ID"

  # 1a. Delete access points FIRST, then wait until none remain.
  #     NOTE: list-access-points count goes STALE during async propagation (it can
  #     report 0 while the AP still exists server-side), so we add a grace sleep AND
  #     rely on the delete-file-system RETRY loop below to absorb the race. This is
  #     what makes the subsequent delete-file-system reliable.
  AP_IDS=$(aws s3files list-access-points --file-system-id "$FS_ID" --region "$REGION" \
    --query "accessPoints[].accessPointId" --output text 2>/dev/null || echo "")
  for AP in $AP_IDS; do
    info "  Deleting access point $AP..."
    OUT=$(aws s3files delete-access-point --access-point-id "$AP" --region "$REGION" 2>&1) \
      || warn "    delete-access-point: $OUT"
  done
  if [ -n "$AP_IDS" ]; then
    info "  Waiting for access points to clear (list count)..."
    for i in $(seq 1 30); do
      REMAINING=$(aws s3files list-access-points --file-system-id "$FS_ID" --region "$REGION" \
        --query "length(accessPoints)" --output text 2>/dev/null || echo "0")
      [ "$REMAINING" = "0" ] && break
      echo "    still $REMAINING access point(s) ($i/30)"; sleep 5
    done
    # The list count can read 0 while deletion is still propagating server-side, which
    # makes an immediate delete-file-system fail with ConflictException. We do NOT rely
    # on the count alone: (a) an unconditional grace sleep here, and (b) the
    # delete-file-system RETRY loop below (which re-attempts for minutes) absorb the race.
    info "  Grace period for access-point deletion to propagate..."
    sleep 20
  fi

  # 1b. Delete mount targets, then wait until none remain (releases the subnet ENIs).
  for MT in $(aws s3files list-mount-targets --file-system-id "$FS_ID" --region "$REGION" \
      --query "mountTargets[].mountTargetId" --output text 2>/dev/null); do
    info "  Deleting mount target $MT..."
    OUT=$(aws s3files delete-mount-target --mount-target-id "$MT" --region "$REGION" 2>&1) \
      || warn "    delete-mount-target: $OUT"
  done
  info "  Waiting for mount targets to clear (ENIs release)..."
  for i in $(seq 1 30); do
    REMAINING=$(aws s3files list-mount-targets --file-system-id "$FS_ID" --region "$REGION" \
      --query "length(mountTargets)" --output text 2>/dev/null || echo "0")
    [ "$REMAINING" = "0" ] && break
    echo "    still $REMAINING mount target(s) ($i/30)"; sleep 10
  done

  # 1c. Now delete the filesystem, retrying while it reports lingering dependencies,
  #     then poll until it is actually gone. Surface the real error if it persists.
  info "  Deleting filesystem $FS_ID..."
  for i in $(seq 1 18); do
    if OUT=$(aws s3files delete-file-system --file-system-id "$FS_ID" --region "$REGION" 2>&1); then
      break
    fi
    if echo "$OUT" | grep -qi "FileSystemNotFound"; then
      break
    fi
    # Common transient cause: access point / mount target still propagating.
    warn "    delete-file-system not ready ($i/18): $(echo "$OUT" | tr '\n' ' ' | tail -c 160)"
    sleep 15
  done
  # Confirm it is actually gone.
  STILL=$(aws s3files list-file-systems --region "$REGION" \
    --query "fileSystems[?fileSystemId=='$FS_ID'].fileSystemId | [0]" --output text 2>/dev/null || echo "")
  if [ -z "$STILL" ] || [ "$STILL" = "None" ] || [ "$STILL" = "null" ]; then
    ok "  S3 Files removed."
  else
    err "  Filesystem $FS_ID still exists after cleanup. Check for remaining access points"
    err "  or mount targets:  aws s3files list-access-points --file-system-id $FS_ID --region $REGION"
    err "  Re-run this script once they clear; terraform destroy will fail until it's gone."
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — Empty the ECR repositories (delete all images)
# ═════════════════════════════════════════════════════════════════════════════
info "STEP 2: empty ECR repositories"
# Derive repo names from terraform output if present, else scan by prefix.
REPOS="$(terraform -chdir="$TERRAFORM_DIR" output -json ecr_repository_urls 2>/dev/null \
  | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(' '.join(u.split('/')[-1] for u in d.values()))
except Exception:
    pass" 2>/dev/null || true)"
if [ -z "$REPOS" ]; then
  REPOS="$(aws ecr describe-repositories --region "$REGION" \
    --query "repositories[?starts_with(repositoryName,'${PREFIX}')].repositoryName" \
    --output text 2>/dev/null || true)"
fi
if [ -z "$REPOS" ]; then
  warn "  No ECR repositories found. Skipping."
else
  for REPO in $REPOS; do
    IDS=$(aws ecr list-images --repository-name "$REPO" --region "$REGION" \
      --query 'imageIds[*]' --output json 2>/dev/null || echo "[]")
    if [ "$IDS" != "[]" ] && [ -n "$IDS" ]; then
      info "  Emptying $REPO..."
      aws ecr batch-delete-image --repository-name "$REPO" --region "$REGION" \
        --image-ids "$IDS" >/dev/null 2>&1 || warn "    (nothing to delete)"
    else
      info "  $REPO already empty."
    fi
  done
  ok "  ECR repositories emptied."
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — Empty the S3 workspace bucket (all object versions + delete markers)
# ═════════════════════════════════════════════════════════════════════════════
info "STEP 3: empty S3 workspace bucket"
if [ -z "${BUCKET:-}" ]; then
  warn "  Bucket name unknown. Skipping (terraform destroy will report if it matters)."
elif ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
  warn "  Bucket '$BUCKET' not found (already deleted?). Skipping."
else
  info "  Purging all versions from $BUCKET..."
  # Delete in batches of up to 1000 (API limit). Loop until empty.
  while true; do
    # shellcheck disable=SC2016 # Backticks are JMESPath literals, not shell syntax.
    JSON=$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" \
      --max-items 1000 \
      --query '{Objects: (Versions[].{Key:Key,VersionId:VersionId})[] || `[]`}' \
      --output json 2>/dev/null || echo '{"Objects":[]}')
    COUNT=$(echo "$JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('Objects') or []))" 2>/dev/null || echo 0)
    [ "$COUNT" = "0" ] && break
    echo "$JSON" | aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" \
      --delete "file:///dev/stdin" >/dev/null 2>&1 || true
    info "    deleted $COUNT version(s)..."
  done
  # Also clear delete markers
  while true; do
    # shellcheck disable=SC2016 # Backticks are JMESPath literals, not shell syntax.
    JSON=$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" \
      --max-items 1000 \
      --query '{Objects: (DeleteMarkers[].{Key:Key,VersionId:VersionId})[] || `[]`}' \
      --output json 2>/dev/null || echo '{"Objects":[]}')
    COUNT=$(echo "$JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('Objects') or []))" 2>/dev/null || echo 0)
    [ "$COUNT" = "0" ] && break
    echo "$JSON" | aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" \
      --delete "file:///dev/stdin" >/dev/null 2>&1 || true
    info "    cleared $COUNT delete marker(s)..."
  done
  ok "  Bucket emptied."
fi

# ─── Done — hand off to terraform destroy ────────────────────────────────────
echo ""
ok "CLI pre-cleanup complete. Now run terraform destroy to remove the rest:"
echo ""
echo "    cd \"$TERRAFORM_DIR\""
echo "    terraform destroy -parallelism=1 -var-file=environments/dev/terraform.tfvars"
echo ""
info "(-parallelism=1 avoids the InvalidSignatureException seen with concurrent requests.)"
info "Afterwards, run scripts/verify_teardown.sh to confirm nothing lingers."
