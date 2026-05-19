variable "cluster_name"      { type = string }
variable "oidc_provider_arn" { type = string }
variable "aws_region"        { type = string; default = "us-east-1" }
variable "hosted_zone_arns"  { type = list(string) }
variable "domain_filters"    { type = list(string) }
variable "tags"              { type = map(string); default = {} }
