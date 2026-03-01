terraform {
  # ~> 1.7 allows 1.7.0 through 1.x but blocks 2.0 (breaking changes expected).
  # Without an upper bound, `terraform init` on a future 2.0 release would succeed
  # but plan/apply could silently produce incorrect infrastructure.
  required_version = "~> 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "aws" {
  region = var.region

  # Default tags applied to ALL AWS resources — ensures consistent cost allocation,
  # ownership tracking, and compliance tagging without repeating in every resource block.
  # IMPORTANT: Do NOT duplicate these keys in resource-level tags — AWS provider 5.x
  # treats duplicates as conflicts, causing plan warnings and perpetual diffs
  # (hashicorp/terraform-provider-aws#19583). Only add resource-specific tags (e.g., Name).
  default_tags {
    tags = {
      Project     = "persons-finder"
      Environment = "dev"
      CostCenter  = "devops-challenge"
      ManagedBy   = "terraform"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# ---------- VPC ----------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  # /19 private subnets (8,190 IPs each) — prevents pod IP exhaustion with VPC CNI.
  # /24 (254 IPs) is insufficient at scale: each pod consumes a VPC IP, and
  # t3.medium supports 17 pods/node × 4 nodes = 68 pods in one AZ alone.
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19"]
  public_subnets  = ["10.0.96.0/24", "10.0.97.0/24", "10.0.98.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  # When single_nat_gateway = false, creates one NAT GW per AZ.
  # This eliminates the cross-AZ SPOF: if one AZ's NAT GW fails,
  # pods in other AZs retain internet access (external LLM, ECR pulls).
  # Cost: ~$32/month per additional NAT GW + data processing fees.
  one_nat_gateway_per_az = !var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # CIS AWS Foundations 4.3 — lock down the default VPC security group.
  # The default SG allows all inbound from itself and all outbound. Nothing
  # should use it (EKS creates dedicated SGs), but restricting it prevents
  # accidental attachment and satisfies compliance benchmarks.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # VPC Flow Logs — required by Well-Architected SEC04-BP01 and CIS AWS 3.7.
  # Captures all accepted/rejected traffic for security monitoring, forensics,
  # and compliance auditing. Without flow logs, network-level attacks (port
  # scanning, lateral movement, data exfiltration) are invisible.
  enable_flow_log                                 = true
  flow_log_destination_type                       = "cloud-watch-logs"
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = 30
  flow_log_max_aggregation_interval               = 60

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  # Tags inherited from provider default_tags — no explicit tags needed.
}

# ---------- EKS ----------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Restrict which IPs can reach the K8s API over the internet.
  # Default 0.0.0.0/0 allows all — set to your VPN/office CIDR in production.
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # API-only authentication — disables the deprecated aws-auth ConfigMap.
  # Benefits: eliminates ConfigMap tampering risk, built-in validation of
  # access entries, CloudTrail-auditable access management, no manual
  # ConfigMap editing errors. This is the AWS-recommended approach per
  # EKS best practices. NOTE: irreversible — cannot revert to CONFIG_MAP.
  authentication_mode = "API"

  # Enable IRSA for service accounts (needed for ESO)
  enable_irsa = true

  # EKS managed addons — converts self-managed defaults to AWS-managed,
  # enabling automatic security patches and version alignment on cluster upgrades
  cluster_addons = {
    coredns = {
      most_recent = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      most_recent = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    vpc-cni = {
      # CRITICAL: Apply VPC-CNI config BEFORE node groups are created.
      # Without this, there's a race condition: nodes join the cluster before
      # ENABLE_NETWORK_POLICY takes effect, so pods start with network policy
      # enforcement disabled — the default-deny and app-specific NetworkPolicies
      # are silently ignored. Per EKS Blueprints best practice.
      before_compute = true
      most_recent    = true
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        env = {
          ENABLE_NETWORK_POLICY = "true"  # Required for K8s NetworkPolicy enforcement
        }
      })
    }
  }

  # All 5 control plane log types — REL06-BP01 (monitor all components).
  # "scheduler" shows why pods are Pending (topology spread, resource constraints).
  # "controllerManager" shows deployment rollout and HPA scaling decisions.
  # Without these, debugging reliability issues requires ephemeral kubectl events.
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # COST04-BP05: 30-day retention for dev (matches VPC flow logs). Audit logs are
  # the most verbose (every K8s API call); 90-day default accumulates significant
  # CloudWatch costs on a dev cluster. Set to 90-365 days for production/compliance.
  cloudwatch_log_group_retention_in_days = 30

  # INFREQUENT_ACCESS class: 50% cheaper ingestion ($0.25 vs $0.50/GB). Control
  # plane logs are for compliance/forensics, not real-time dashboards (Prometheus
  # handles that). Tradeoff: higher CloudWatch Insights query cost — acceptable
  # for occasional troubleshooting.
  cloudwatch_log_group_class = "INFREQUENT_ACCESS"

  # Envelope encryption for Kubernetes secrets at rest
  cluster_encryption_config = {
    resources = ["secrets"]
  }

  eks_managed_node_groups = {
    default = {
      # AL2023 replaces AL2 which reached EKS end-of-support on 2025-11-26.
      # AL2 no longer receives AMI updates (security patches, bug fixes).
      # AL2023 benefits: kernel 6.1, faster boot (~30%), IMDSv2 default, dnf.
      # For managed node groups, the AL2023 nodeadm init is handled by EKS.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # CIS EKS Benchmark — encrypt node EBS volumes at rest. Without this,
      # encryption depends on the account's default EBS encryption setting.
      # Container images, kubelet state, emptyDir volumes, and logs on the
      # node disk are unencrypted if the account default is off.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # IMDSv2 required — prevents pods from accessing node metadata (EKS best practice)
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      labels = {
        role = "general"
      }
    }
  }

  # Allow the current caller to administer the cluster
  enable_cluster_creator_admin_permissions = true

  # Tags inherited from provider default_tags — no explicit tags needed.
}