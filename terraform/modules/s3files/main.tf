# =============================================================================
# S3 Files — persistent shared workspace storage for multi-agent workflows.
#
# Creates:
#   1. S3 bucket (versioning + encryption — required by S3 Files)
#   2. S3 Files access role (assumed by elasticfilesystem.amazonaws.com)
#   3. S3 Files filesystem + mount target(s) + access point (via AWS CLI —
#      there is no native Terraform resource for S3 Files yet)
#
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_region" "replica" {
  provider = aws.replica
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  bucket_name = "${var.project_name}-${var.environment}-agent-workspaces"
}

# --- Workspace encryption keys ----------------------------------------------
# Workspace data uses dedicated customer-managed keys in each Region. S3 access
# log buckets remain on SSE-S3 because S3 server access-log delivery does not
# support SSE-KMS destination buckets.
resource "aws_kms_key" "workspaces" {
  description             = "Encrypt ${local.bucket_name} workspace data"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableRootAccountAdmin"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = { Name = "${local.bucket_name}-kms" }
}

resource "aws_kms_alias" "workspaces" {
  name          = "alias/${local.bucket_name}"
  target_key_id = aws_kms_key.workspaces.key_id
}

resource "aws_kms_key" "workspaces_replica" {
  provider                = aws.replica
  description             = "Encrypt ${local.bucket_name} replica workspace data"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableRootAccountAdmin"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = { Name = "${local.bucket_name}-replica-kms" }
}

resource "aws_kms_alias" "workspaces_replica" {
  provider      = aws.replica
  name          = "alias/${local.bucket_name}"
  target_key_id = aws_kms_key.workspaces_replica.key_id
}

# --- Access-log bucket -------------------------------------------------------
# Receives S3 server access logs for the workspace bucket (checkov CKV_AWS_18).
# Hardened the same way as the workspace bucket. A bucket cannot log to itself, so
# this log bucket does not itself enable access logging (that would recurse).
resource "aws_s3_bucket" "access_logs" {
  #checkov:skip=CKV_AWS_145:S3 server access-log destination buckets do not support SSE-KMS; this bucket explicitly uses SSE-S3 (AES256).
  bucket = "${local.bucket_name}-access-logs"
  tags   = { Purpose = "S3 server access logs for the agent workspace bucket" }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs disabled (checkov CKV2_AWS_65). Modern S3 server access logging delivers via
# the logging.s3.amazonaws.com service principal + a bucket policy (below), so no ACLs
# are needed.
resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

# Allow S3 log delivery to write access logs for the workspace bucket (ACL-free path).
resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3ServerAccessLogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs.arn}/*"
        Condition = {
          ArnLike      = { "aws:SourceArn" = aws_s3_bucket.workspaces.arn }
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration { days = var.retention_days }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

# Event notifications via EventBridge (checkov CKV2_AWS_62). EventBridge needs no
# SNS/SQS target to satisfy the check and incurs no cost until a rule consumes events.
resource "aws_s3_bucket_notification" "access_logs" {
  bucket      = aws_s3_bucket.access_logs.id
  eventbridge = true
}

# --- S3 Bucket ---------------------------------------------------------------

resource "aws_s3_bucket" "workspaces" {
  bucket = local.bucket_name
  tags   = { Purpose = "Shared agent workspace storage via S3 Files" }
}

resource "aws_s3_bucket_policy" "workspaces" {
  bucket = aws_s3_bucket.workspaces.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.workspaces.arn, "${aws_s3_bucket.workspaces.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# Server access logging -> dedicated log bucket (checkov CKV_AWS_18).
resource "aws_s3_bucket_logging" "workspaces" {
  bucket        = aws_s3_bucket.workspaces.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "workspace-access-logs/"

  depends_on = [aws_s3_bucket_policy.access_logs]
}

resource "aws_s3_bucket_versioning" "workspaces" {
  bucket = aws_s3_bucket.workspaces.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "workspaces" {
  bucket = aws_s3_bucket.workspaces.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.workspaces.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "workspaces" {
  bucket                  = aws_s3_bucket.workspaces.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "workspaces" {
  bucket = aws_s3_bucket.workspaces.id

  # Retention applies only to managed workspace objects.
  rule {
    id     = "expire-workspace-artifacts"
    status = "Enabled"
    filter { prefix = var.workspace_prefix }
    expiration { days = var.retention_days }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }

  # Multipart uploads can be initiated outside workspace_prefix, so clean them up
  # across the entire bucket (checkov CKV_AWS_300).
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

# Event notifications via EventBridge (checkov CKV2_AWS_62).
resource "aws_s3_bucket_notification" "workspaces" {
  bucket      = aws_s3_bucket.workspaces.id
  eventbridge = true
}

# --- S3 Files Access Role (per official docs) --------------------------------
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-files-prereq-policies.html

resource "aws_iam_role" "s3files_access" {
  name = "${var.project_name}-${var.environment}-s3files-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowS3FilesAssumeRole"
      Effect    = "Allow"
      Principal = { Service = "elasticfilesystem.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:s3files:${local.region}:${local.account_id}:file-system/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "s3files_bucket_access" {
  name = "s3files-bucket-access"
  role = aws_iam_role.s3files_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "S3BucketPermissions"
        Effect    = "Allow"
        Action    = ["s3:ListBucket", "s3:ListBucketVersions"]
        Resource  = aws_s3_bucket.workspaces.arn
        Condition = { StringEquals = { "aws:ResourceAccount" = local.account_id } }
      },
      {
        Sid       = "S3ObjectPermissions"
        Effect    = "Allow"
        Action    = ["s3:AbortMultipartUpload", "s3:DeleteObject*", "s3:GetObject*", "s3:List*", "s3:PutObject*"]
        Resource  = "${aws_s3_bucket.workspaces.arn}/*"
        Condition = { StringEquals = { "aws:ResourceAccount" = local.account_id } }
      },
      {
        Sid    = "KmsWorkspaceData"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:ReEncrypt*",
        ]
        Resource = aws_kms_key.workspaces.arn
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
            "kms:ViaService"    = "s3.${local.region}.amazonaws.com"
          }
        }
      },
      {
        Sid       = "EventBridgeManage"
        Effect    = "Allow"
        Action    = ["events:DeleteRule", "events:DisableRule", "events:EnableRule", "events:PutRule", "events:PutTargets", "events:RemoveTargets"]
        Condition = { StringEquals = { "events:ManagedBy" = "elasticfilesystem.amazonaws.com" } }
        Resource  = ["arn:aws:events:*:*:rule/DO-NOT-DELETE-S3-Files*"]
      },
      {
        Sid      = "EventBridgeRead"
        Effect   = "Allow"
        Action   = ["events:DescribeRule", "events:ListRuleNamesByTarget", "events:ListRules", "events:ListTargetsByRule"]
        Resource = ["arn:aws:events:*:*:rule/*"]
      },
    ]
  })
}

# --- S3 Files Filesystem + Mount Target + Access Point (via AWS CLI) ---------

resource "null_resource" "s3files_filesystem" {
  count = var.create_s3files ? 1 : 0

  triggers = {
    bucket_arn         = aws_s3_bucket.workspaces.arn
    role_arn           = aws_iam_role.s3files_access.arn
    access_point_uid   = "1000"
    access_point_gid   = "1000"
    access_point_perms = "750"
    access_point_paths = "/agentcore/repositories,/agentcore/workspaces"
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      REGION="${local.region}"
      BUCKET_ARN="${aws_s3_bucket.workspaces.arn}"
      ROLE_ARN="${aws_iam_role.s3files_access.arn}"
      SG_ID="${var.security_group_id}"

      FS_ID=$(aws s3files list-file-systems --region "$REGION" \
        --query "fileSystems[?bucket=='$BUCKET_ARN'].fileSystemId | [0]" --output text 2>/dev/null || echo "")

      if [ -n "$FS_ID" ] && [ "$FS_ID" != "None" ] && [ "$FS_ID" != "null" ]; then
        echo "S3 Files filesystem already exists: $FS_ID"
      else
        echo "Creating S3 Files filesystem..."
        FS_RESULT=$(aws s3files create-file-system --region "$REGION" \
          --bucket "$BUCKET_ARN" --role-arn "$ROLE_ARN" --output json)
        FS_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin)['fileSystemId'])" <<< "$FS_RESULT")
        echo "Filesystem created: $FS_ID"
        for i in $(seq 1 60); do
          STATUS=$(aws s3files get-file-system --file-system-id "$FS_ID" --region "$REGION" --query "status" --output text)
          echo "  Status: $STATUS ($i/60)"
          if [ "$STATUS" = "available" ]; then break; fi
          sleep 10
        done
        if [ "$STATUS" != "available" ]; then echo "ERROR: filesystem not available after 10m"; exit 1; fi
      fi

      SUBNET_IDS="${join(",", var.vpc_subnet_ids)}"
      for SUBNET_ID in $(echo "$SUBNET_IDS" | tr ',' ' '); do
        EXISTING_MT=$(aws s3files list-mount-targets --file-system-id "$FS_ID" --region "$REGION" \
          --query "mountTargets[?subnetId=='$SUBNET_ID'].mountTargetId | [0]" --output text 2>/dev/null || echo "")
        if [ -n "$EXISTING_MT" ] && [ "$EXISTING_MT" != "None" ]; then
          echo "Mount target already exists in $SUBNET_ID: $EXISTING_MT"
        else
          echo "Creating mount target in $SUBNET_ID..."
          aws s3files create-mount-target --file-system-id "$FS_ID" --subnet-id "$SUBNET_ID" \
            --security-groups "$SG_ID" --region "$REGION" --output json 2>&1 || true
        fi
      done

      for i in $(seq 1 60); do
        MT_STATUS=$(aws s3files list-mount-targets --file-system-id "$FS_ID" --region "$REGION" --query "mountTargets[0].status" --output text 2>/dev/null || echo "creating")
        echo "  Mount target status: $MT_STATUS ($i/60)"
        if [ "$MT_STATUS" = "available" ]; then break; fi
        sleep 10
      done
      if [ "$MT_STATUS" != "available" ]; then echo "ERROR: mount target not available after 10m"; exit 1; fi

      for AP_SPEC in "repositories|/agentcore/repositories" "workspaces|/agentcore/workspaces"; do
        AP_NAME="$${AP_SPEC%%|*}"
        AP_PATH="$${AP_SPEC#*|}"
        AP_ARN=$(aws s3files list-access-points --file-system-id "$FS_ID" --region "$REGION" --output json \
          | python3 -c 'import json,sys; path=sys.argv[1]; points=json.load(sys.stdin).get("accessPoints", []); print(next((p.get("accessPointArn", "") for p in points if p.get("posixUser", {}).get("uid") == 1000 and p.get("posixUser", {}).get("gid") == 1000 and p.get("rootDirectory", {}).get("path") == path), ""))' "$AP_PATH")
        if [ -n "$AP_ARN" ]; then
          echo "Dedicated $AP_NAME access point already exists: $AP_ARN"
        else
          echo "Creating dedicated $AP_NAME access point..."
          AP_RESULT=$(aws s3files create-access-point --file-system-id "$FS_ID" \
            --posix-user "uid=1000,gid=1000" \
            --root-directory "path=$AP_PATH,creationPermissions={ownerUid=1000,ownerGid=1000,permissions=750}" \
            --tags "key=Purpose,value=agentcore-$AP_NAME-runtime" \
            --region "$REGION" --output json)
          AP_ARN=$(python3 -c "import json,sys; print(json.load(sys.stdin)['accessPointArn'])" <<< "$AP_RESULT")
          echo "Dedicated $AP_NAME access point created: $AP_ARN"
        fi
      done

      echo "S3 Files ready: fs=$FS_ID with dedicated repositories/workspaces access points"
    EOT
  }

  depends_on = [
    aws_s3_bucket.workspaces,
    aws_s3_bucket_versioning.workspaces,
    aws_s3_bucket_server_side_encryption_configuration.workspaces,
    aws_iam_role_policy.s3files_bucket_access,
  ]
}

data "external" "s3files_lookup" {
  count = var.create_s3files ? 1 : 0
  program = ["bash", "-c", <<-EOT
    REGION="${local.region}"
    BUCKET_ARN="${aws_s3_bucket.workspaces.arn}"
    FS_ID=$(aws s3files list-file-systems --region "$REGION" \
      --query "fileSystems[?bucket=='$BUCKET_ARN'].fileSystemId | [0]" --output text 2>/dev/null || echo "")
    if [ -z "$FS_ID" ] || [ "$FS_ID" = "None" ] || [ "$FS_ID" = "null" ]; then
      echo '{"filesystem_id": "", "mount_target_ip": "", "repositories_access_point_arn": "", "workspaces_access_point_arn": ""}'; exit 0
    fi
    MT_IP=$(aws s3files list-mount-targets --file-system-id "$FS_ID" --region "$REGION" \
      --query "mountTargets[0].ipv4Address" --output text 2>/dev/null || echo "")
    if [ "$MT_IP" = "None" ] || [ "$MT_IP" = "null" ]; then MT_IP=""; fi
    ACCESS_POINTS=$(aws s3files list-access-points --file-system-id "$FS_ID" --region "$REGION" --output json)
    REPOSITORIES_AP_ARN=$(python3 -c 'import json,sys; path="/agentcore/repositories"; points=json.load(sys.stdin).get("accessPoints", []); print(next((p.get("accessPointArn", "") for p in points if p.get("posixUser", {}).get("uid") == 1000 and p.get("posixUser", {}).get("gid") == 1000 and p.get("rootDirectory", {}).get("path") == path), ""))' <<< "$ACCESS_POINTS")
    WORKSPACES_AP_ARN=$(python3 -c 'import json,sys; path="/agentcore/workspaces"; points=json.load(sys.stdin).get("accessPoints", []); print(next((p.get("accessPointArn", "") for p in points if p.get("posixUser", {}).get("uid") == 1000 and p.get("posixUser", {}).get("gid") == 1000 and p.get("rootDirectory", {}).get("path") == path), ""))' <<< "$ACCESS_POINTS")
    echo "{\"filesystem_id\": \"$FS_ID\", \"mount_target_ip\": \"$MT_IP\", \"repositories_access_point_arn\": \"$REPOSITORIES_AP_ARN\", \"workspaces_access_point_arn\": \"$WORKSPACES_AP_ARN\"}"
  EOT
  ]
  depends_on = [null_resource.s3files_filesystem]
}

# =============================================================================
# Cross-region replication (checkov CKV_AWS_144) for the workspace + access-log
# buckets. Replica buckets live in the aws.replica region, versioned + encrypted +
# public-access-blocked. A replication IAM role grants S3 the needed read/write.
# =============================================================================

# --- Replica buckets (secondary region) --------------------------------------
resource "aws_s3_bucket" "workspaces_replica" {
  provider = aws.replica
  bucket   = "${local.bucket_name}-replica"
  tags     = { Purpose = "Cross-region replica of the agent workspace bucket" }
}

resource "aws_s3_bucket_versioning" "workspaces_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.workspaces_replica.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "workspaces_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.workspaces_replica.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.workspaces_replica.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "workspaces_replica" {
  provider                = aws.replica
  bucket                  = aws_s3_bucket.workspaces_replica.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "workspaces_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.workspaces_replica.id
  rule {
    id     = "expire-replica"
    status = "Enabled"
    filter {}
    expiration { days = var.retention_days }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_s3_bucket_notification" "workspaces_replica" {
  provider    = aws.replica
  bucket      = aws_s3_bucket.workspaces_replica.id
  eventbridge = true
}

resource "aws_s3_bucket_policy" "workspaces_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.workspaces_replica.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.workspaces_replica.arn,
        "${aws_s3_bucket.workspaces_replica.arn}/*",
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket" "access_logs_replica" {
  #checkov:skip=CKV_AWS_145:Replica of the S3 access-log bucket; keep SSE-S3 because server access-log destination buckets do not support SSE-KMS.
  provider = aws.replica
  bucket   = "${local.bucket_name}-access-logs-replica"
  tags     = { Purpose = "Cross-region replica of the access-log bucket" }
}

resource "aws_s3_bucket_versioning" "access_logs_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.access_logs_replica.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.access_logs_replica.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs_replica" {
  provider                = aws.replica
  bucket                  = aws_s3_bucket.access_logs_replica.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "access_logs_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.access_logs_replica.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

# Allow access-log delivery for the replica workspace bucket. The target stays
# private and accepts writes only from S3 logging for this account and source.
resource "aws_s3_bucket_policy" "access_logs_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.access_logs_replica.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowReplicaS3ServerAccessLogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs_replica.arn}/*"
        Condition = {
          ArnLike      = { "aws:SourceArn" = aws_s3_bucket.workspaces_replica.arn }
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.access_logs_replica.arn,
          "${aws_s3_bucket.access_logs_replica.arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

# Log access to the replicated workspace into the replica-region log bucket.
# Checkov treats a bucket used as a logging target as the terminal log sink, so
# the destination does not recursively log to another bucket (CKV_AWS_18).
resource "aws_s3_bucket_logging" "workspaces_replica" {
  provider      = aws.replica
  bucket        = aws_s3_bucket.workspaces_replica.id
  target_bucket = aws_s3_bucket.access_logs_replica.id
  target_prefix = "workspace-replica-access-logs/"

  depends_on = [aws_s3_bucket_policy.access_logs_replica]
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.access_logs_replica.id
  rule {
    id     = "expire-replica"
    status = "Enabled"
    filter {}
    expiration { days = var.retention_days }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

resource "aws_s3_bucket_notification" "access_logs_replica" {
  provider    = aws.replica
  bucket      = aws_s3_bucket.access_logs_replica.id
  eventbridge = true
}

# --- Replication IAM role -----------------------------------------------------
resource "aws_iam_role" "replication" {
  name = "${var.project_name}-${var.environment}-s3-replication"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.account_id
        }
        ArnLike = {
          "aws:SourceArn" = [
            aws_s3_bucket.workspaces.arn,
            aws_s3_bucket.access_logs.arn,
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "replication" {
  name = "s3-replication"
  role = aws_iam_role.replication.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = [aws_s3_bucket.workspaces.arn, aws_s3_bucket.access_logs.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Resource = ["${aws_s3_bucket.workspaces.arn}/*", "${aws_s3_bucket.access_logs.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Resource = ["${aws_s3_bucket.workspaces_replica.arn}/*", "${aws_s3_bucket.access_logs_replica.arn}/*"]
      },
      {
        Sid      = "DecryptWorkspaceSource"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.workspaces.arn
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
            "kms:ViaService"    = "s3.${local.region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "EncryptWorkspaceReplica"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:ReEncrypt*",
        ]
        Resource = aws_kms_key.workspaces_replica.arn
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
            "kms:ViaService"    = "s3.${data.aws_region.replica.region}.amazonaws.com"
          }
        }
      },
    ]
  })
}

# --- Replication configuration on the source buckets --------------------------
# Depends on versioning being enabled on both source and destination.
resource "aws_s3_bucket_replication_configuration" "workspaces" {
  bucket = aws_s3_bucket.workspaces.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "replicate-all"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Enabled" }
    source_selection_criteria {
      sse_kms_encrypted_objects { status = "Enabled" }
    }
    destination {
      bucket        = aws_s3_bucket.workspaces_replica.arn
      storage_class = "STANDARD"
      encryption_configuration {
        replica_kms_key_id = aws_kms_key.workspaces_replica.arn
      }
    }
  }

  depends_on = [
    aws_iam_role_policy.replication,
    aws_s3_bucket_versioning.workspaces,
    aws_s3_bucket_versioning.workspaces_replica,
  ]
}

resource "aws_s3_bucket_replication_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "replicate-all"
    status = "Enabled"
    filter {}
    delete_marker_replication { status = "Enabled" }
    destination {
      bucket        = aws_s3_bucket.access_logs_replica.arn
      storage_class = "STANDARD"
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.access_logs,
    aws_s3_bucket_versioning.access_logs_replica,
  ]
}
