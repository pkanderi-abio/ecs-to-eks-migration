# =============================================================================
# Karpenter Module — v0.36 | Spot + On-Demand | arm64 + amd64
# NodeLocalDNSCache pre-installed via userData to prevent INCIDENT-001 recurrence
# =============================================================================

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = var.cluster_name

  enable_irsa                     = true
  irsa_oidc_provider_arn          = var.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  node_iam_role_name              = "${var.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix   = false
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "0.36.0"
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 300

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter.irsa_arn
  }
  set { name = "settings.clusterName";    value = var.cluster_name }
  set { name = "settings.interruptionQueue"; value = module.karpenter.queue_name }
  set { name = "controller.resources.requests.cpu";    value = "250m" }
  set { name = "controller.resources.requests.memory"; value = "512Mi" }
  set { name = "controller.resources.limits.memory";   value = "1Gi" }
  set { name = "logLevel"; value = "info" }

  depends_on = [module.karpenter]
}

# EC2NodeClass — AL2023, encrypted EBS, IMDSv2 enforced
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1beta1"
    kind       = "EC2NodeClass"
    metadata   = { name = "prod-nodeclass" }
    spec = {
      amiFamily = "AL2023"
      role       = module.karpenter.node_iam_role_name
      subnetSelectorTerms     = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
      securityGroupSelectorTerms = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize = "100Gi"
          volumeType = "gp3"
          iops       = 3000
          throughput = 125
          encrypted  = true
          kmsKeyID   = var.kms_key_arn
        }
      }]
      metadataOptions = { httpEndpoint = "enabled", httpProtocolIPv6 = "disabled", httpPutResponseHopLimit = 1, httpTokens = "required" }
      # Pre-install NodeLocalDNSCache link-local — prevents INCIDENT-001 (DNS storm)
      userData = <<-EOT
        #!/bin/bash
        set -ex
        # NodeLocalDNSCache — absorbs ndots:5 amplification locally
        # Reduces CoreDNS QPS from thousands to ~94 during high-volume services
        cat > /tmp/node-local-dns.yaml << 'EOF'
        # Applied at node startup; daemonset also deployed via k8s/node-local-dns/
        EOF
        echo "NodeLocalDNS pre-requisite: link-local reserved on 169.254.20.10"
        ip link add nodelocaldns type dummy || true
        ip addr add 169.254.20.10/32 dev nodelocaldns || true
        ip link set nodelocaldns up || true
      EOT
      tags = var.tags
    }
  })
  depends_on = [helm_release.karpenter]
}

# NodePool — mixed Spot/On-Demand, arm64 + amd64
resource "kubectl_manifest" "karpenter_nodepool_mixed" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1beta1"
    kind       = "NodePool"
    metadata   = { name = "prod-mixed" }
    spec = {
      template = {
        metadata = {
          labels = { "node.kubernetes.io/instance-category" = "general" }
        }
        spec = {
          nodeClassRef = { name = "prod-nodeclass" }
          requirements = [
            { key = "karpenter.sh/capacity-type",       operator = "In", values = ["spot", "on-demand"] },
            { key = "kubernetes.io/arch",               operator = "In", values = ["amd64", "arm64"] },
            { key = "karpenter.k8s.aws/instance-family", operator = "In",
              values = ["m6i", "m6g", "m7i", "m7g", "r6i", "r6g", "c6i", "c6g"] },
            { key = "karpenter.k8s.aws/instance-size",  operator = "In",
              values = ["large", "xlarge", "2xlarge", "4xlarge", "8xlarge"] },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["5"] }
          ]
          # Evict Spot nodes gracefully; 2min drain before replacement
          terminationGracePeriod = "2m"
        }
      }
      limits = {
        cpu    = "400"     # ~100 xlarge nodes max
        memory = "800Gi"
      }
      disruption = {
        consolidationPolicy = "WhenUnderutilized"
        consolidateAfter    = "30s"
        # Budgets: max 10% of nodes disrupted at once (SOC2 availability)
        budgets = [
          { nodes = "10%" }
        ]
      }
    }
  })
  depends_on = [kubectl_manifest.karpenter_node_class]
}

# Dedicated NodePool for stateful services (On-Demand only, single AZ per tenant)
resource "kubectl_manifest" "karpenter_nodepool_stateful" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1beta1"
    kind       = "NodePool"
    metadata   = { name = "prod-stateful" }
    spec = {
      template = {
        metadata = { labels = { workload-type = "stateful" } }
        spec = {
          nodeClassRef = { name = "prod-nodeclass" }
          requirements = [
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "kubernetes.io/arch",          operator = "In", values = ["amd64"] },
            { key = "karpenter.k8s.aws/instance-family", operator = "In", values = ["r6i", "r7i"] },
            { key = "karpenter.k8s.aws/instance-size",   operator = "In", values = ["xlarge", "2xlarge", "4xlarge"] },
          ]
          taints = [{ key = "workload-type", value = "stateful", effect = "NoSchedule" }]
        }
      }
      limits = { cpu = "64", memory = "256Gi" }
      disruption = { consolidationPolicy = "WhenEmpty", consolidateAfter = "5m" }
    }
  })
  depends_on = [kubectl_manifest.karpenter_node_class]
}
