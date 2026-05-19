# =============================================================================
# EKS Cluster Module — Production Grade
# EKS v1.29 | Private endpoint | IRSA | Multi-AZ | SOC2 + HIPAA compliant
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Private-only endpoint — required for SOC2 CC6.6 + HIPAA
  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  # IRSA — required for Karpenter, ALB Controller, ExternalDNS, ExternalSecrets
  enable_irsa = true

  # Cluster-level logging for CloudTrail + SIEM integration
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Managed addons — keep current, security patches auto-applied
  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        replicaCount = 3
        resources = {
          limits   = { cpu = "200m", memory = "256Mi" }
          requests = { cpu = "100m", memory = "128Mi" }
        }
      })
    }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          # Prefix delegation — 110 pods/node on m6i.4xlarge (vs 29 default)
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
          MINIMUM_IP_TARGET        = "5"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
    }
    aws-efs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.efs_csi_irsa_role.iam_role_arn
    }
  }

  # Bootstrap managed node group — Karpenter takes over post-bootstrap
  eks_managed_node_groups = {
    bootstrap = {
      name           = "${var.cluster_name}-bootstrap"
      instance_types = ["m6i.large"]
      min_size       = 3
      max_size       = 6
      desired_size   = 3

      # Taint so only system pods schedule here
      taints = [
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      ]
      labels = {
        role                 = "bootstrap"
        "karpenter.sh/excluded" = "true"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            kms_key_id            = var.kms_key_arn
            delete_on_termination = true
          }
        }
      }
    }
  }

  # Node-level security group — referenced by EFS, ElastiCache, RDS SG rules
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
    # Karpenter webhook
    ingress_karpenter_webhook = {
      description                   = "Karpenter webhook"
      protocol                      = "tcp"
      from_port                     = 8443
      to_port                       = 8443
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  tags = merge(var.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# IRSA roles for EBS + EFS CSI drivers
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = var.tags
}

module "efs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${var.cluster_name}-efs-csi"
  attach_efs_csi_policy = true
  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
  tags = var.tags
}

# EFS Security Group — allows inbound NFS from EKS nodes
# INCIDENT-002 root cause: this rule was missing on initial deploy
resource "aws_security_group_rule" "efs_from_eks_nodes" {
  count                    = var.efs_security_group_id != "" ? 1 : 0
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = module.eks.node_security_group_id
  security_group_id        = var.efs_security_group_id
  description              = "EFS NFS from EKS nodes (INCIDENT-002 fix)"
}
