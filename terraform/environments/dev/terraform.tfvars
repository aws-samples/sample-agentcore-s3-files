# Development environment variables — used with:
#   terraform plan -var-file=environments/dev/terraform.tfvars -out=tfplan
#
# Region + naming only. The AWS ACCOUNT is chosen by your credentials
# (export AWS_PROFILE=...), never set here.
project_name   = "agentcore-s3files"
environment    = "dev"
aws_region     = "ap-southeast-1"
replica_region = "ap-southeast-2"
# log_level  = "INFO"   # optional; falls back to config.yaml
