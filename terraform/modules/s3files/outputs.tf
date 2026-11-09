output "bucket_name" {
  description = "S3 bucket name for agent workspaces"
  value       = aws_s3_bucket.workspaces.bucket
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.workspaces.arn
}

output "s3files_access_role_arn" {
  description = "IAM role ARN for S3 Files access"
  value       = aws_iam_role.s3files_access.arn
}

output "filesystem_id" {
  description = "S3 Files filesystem ID (empty if not created yet)"
  value = var.create_s3files && length(data.external.s3files_lookup) > 0 ? (
    try(data.external.s3files_lookup[0].result.filesystem_id, "")
  ) : ""
}

output "mount_target_ip" {
  description = "S3 Files mount target IP (empty if not created yet)"
  value = var.create_s3files && length(data.external.s3files_lookup) > 0 ? (
    try(data.external.s3files_lookup[0].result.mount_target_ip, "")
  ) : ""
}

output "access_point_arns" {
  description = "Dedicated S3 Files access point ARNs for repositories and workspaces"
  value = var.create_s3files && length(data.external.s3files_lookup) > 0 ? {
    repositories = try(data.external.s3files_lookup[0].result.repositories_access_point_arn, "")
    workspaces   = try(data.external.s3files_lookup[0].result.workspaces_access_point_arn, "")
    } : {
    repositories = ""
    workspaces   = ""
  }
}

output "workspace_kms_key_arn" {
  description = "Primary-region KMS key ARN used by the workspace bucket"
  value       = aws_kms_key.workspaces.arn
}

output "workspace_replica_kms_key_arn" {
  description = "Replica-region KMS key ARN used by the workspace replica bucket"
  value       = aws_kms_key.workspaces_replica.arn
}
