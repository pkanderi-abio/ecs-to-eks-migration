variable "cluster_version"       { type = string; default = "1.29" }
variable "efs_security_group_id" { type = string; description = "EFS SG — EKS nodes need inbound 2049 (INCIDENT-002 fix)" }
variable "hosted_zone_arns"      { type = list(string) }
variable "domain_filters"        { type = list(string); default = ["prod.example.com"] }
