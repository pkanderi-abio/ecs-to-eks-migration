output "irsa_arn"           { value = module.karpenter.irsa_arn }
output "node_role_arn"      { value = module.karpenter.node_iam_role_arn }
output "queue_name"         { value = module.karpenter.queue_name }
