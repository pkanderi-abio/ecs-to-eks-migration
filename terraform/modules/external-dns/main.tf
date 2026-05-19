# =============================================================================
# ExternalDNS — syncs Service/Ingress to Route53
# Scoped to prod-*.example.com zones only (least-privilege)
# =============================================================================

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                     = "${var.cluster_name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = var.hosted_zone_arns

  oidc_providers = {
    ex = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }
  tags = var.tags
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = "1.14.3"
  namespace        = "external-dns"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    provider = "aws"
    aws = {
      region           = var.aws_region
      preferCNAME      = true
      evaluateTargetHealth = true
    }
    domainFilters = var.domain_filters
    policy        = "sync"  # allow deletes — production safe with domainFilters scoped
    txtOwnerId    = var.cluster_name

    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.external_dns_irsa.iam_role_arn
      }
    }

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  })]
}
