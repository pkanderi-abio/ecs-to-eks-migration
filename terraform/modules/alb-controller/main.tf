# =============================================================================
# AWS Load Balancer Controller v2.7 via IRSA
# Replaces ECS ALB target group attachments with Kubernetes Ingress/Service
# =============================================================================

module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                              = "${var.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
  tags = var.tags
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.2"
  namespace  = "kube-system"
  wait       = true
  timeout    = 300

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.aws_region
    vpcId       = var.vpc_id

    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.alb_controller_irsa.iam_role_arn
      }
    }

    replicaCount = 2

    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "256Mi" }
    }

    # Tolerate bootstrap nodes during initial deploy
    tolerations = [{
      key      = "CriticalAddonsOnly"
      operator = "Exists"
      effect   = "NoSchedule"
    }]

    # Pod disruption budget — keep 1 controller always up
    podDisruptionBudget = { maxUnavailable = 1 }
  })]
}
