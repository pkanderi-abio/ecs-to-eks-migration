variable "cluster_name"      { type = string }
variable "oidc_provider_arn" { type = string }
variable "vpc_id"            { type = string }
variable "aws_region"        { type = string; default = "us-east-1" }
variable "tags"              { type = map(string); default = {} }
