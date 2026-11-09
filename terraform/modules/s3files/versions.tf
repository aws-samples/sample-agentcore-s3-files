# The s3files module uses TWO aws provider configurations:
#   aws          — primary region (bucket, IAM, S3 Files filesystem/mount/access points)
#   aws.replica  — secondary region, for S3 cross-region replication targets
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.50"
      configuration_aliases = [aws.replica]
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
