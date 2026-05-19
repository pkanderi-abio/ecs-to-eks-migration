output "cluster_name"              { value = module.eks.cluster_name }
output "cluster_endpoint"          { value = module.eks.cluster_endpoint; sensitive = true }
output "node_security_group_id"    { value = module.eks.node_security_group_id }
output "oidc_provider_arn"         { value = module.eks.oidc_provider_arn }
output "karpenter_node_role_arn"   { value = module.karpenter.node_role_arn }
