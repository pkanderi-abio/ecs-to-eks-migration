variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "vpc_id" {
  description = "VPC ID — must be the same VPC as ECS cluster for migration"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs across 3 AZs"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS CMK ARN for EBS volume encryption"
  type        = string
}

variable "efs_security_group_id" {
  description = "Existing EFS security group ID (for INCIDENT-002 fix rule)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
