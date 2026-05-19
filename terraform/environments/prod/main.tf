# =============================================================================
# PRODUCTION EKS Environment
# us-east-1 | 3-AZ | Same VPC as ECS (critical for migration window)
# =============================================================================

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws        = { source = "hashicorp/aws",    version = "~> 5.40" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.27" }
    helm       = { source = "hashicorp/helm",   version = "~> 2.13" }
    kubectl    = { source = "gavinbunney/kubectl", version = "~> 1.14" }
  }
  backend "s3" {
    bucket         = "abio-terraform-state-prod"
    key            = "eks/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "abio-terraform-locks"
    encrypt        = true
    kms_key_id     = "alias/terraform-state-cmk"
  }
}

provider "aws" {
  region = local.region
  default_tags {
    tags = local.common_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
    }
  }
}

locals {
  region       = "us-east-1"
  cluster_name = "prod-eks-us-east-1"
  common_tags = {
    Environment   = "production"
    Project       = "platform"
    ManagedBy     = "terraform"
    Owner         = "platform-team"
    CostCenter    = "infra-001"
    Compliance    = "hipaa,soc2"
    "ecs-migration" = "complete"
  }
}

# ── Data sources — reuse existing VPC/subnets shared with ECS
data "aws_vpc" "prod" { tags = { Name = "prod-vpc" } }

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.prod.id]
  }
  tags = { Tier = "private" }
}

data "aws_kms_key" "prod_cmk" { key_id = "alias/prod-eks-cmk" }

# ── EKS Cluster
module "eks" {
  source          = "../../modules/eks-cluster"
  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = data.aws_vpc.prod.id
  subnet_ids      = data.aws_subnets.private.ids
  kms_key_arn     = data.aws_kms_key.prod_cmk.arn
  efs_security_group_id = var.efs_security_group_id  # INCIDENT-002 fix
  tags            = local.common_tags
}

# ── Karpenter
module "karpenter" {
  source            = "../../modules/karpenter"
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  kms_key_arn       = data.aws_kms_key.prod_cmk.arn
  tags              = local.common_tags
  depends_on        = [module.eks]
}

# ── AWS Load Balancer Controller
module "alb_controller" {
  source            = "../../modules/alb-controller"
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  vpc_id            = data.aws_vpc.prod.id
  aws_region        = local.region
  tags              = local.common_tags
  depends_on        = [module.eks]
}

# ── ExternalDNS
module "external_dns" {
  source            = "../../modules/external-dns"
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  aws_region        = local.region
  hosted_zone_arns  = var.hosted_zone_arns
  domain_filters    = var.domain_filters
  tags              = local.common_tags
  depends_on        = [module.eks]
}
