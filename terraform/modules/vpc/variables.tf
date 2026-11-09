variable "application_name" {
  description = "Name of the application"
  type        = string
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
}

variable "vpc_config" {
  description = "VPC configuration from config.yaml"
  type        = any
  default     = {}
}
