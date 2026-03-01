variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "persons-finder"
}

variable "cluster_version" {
  description = "Kubernetes version. Check the EKS release calendar for support dates: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html"
  type        = string
  # EKS 1.29 extended support ended March 23, 2026 (auto-upgrade after that date).
  # 1.32 is in standard support until March 23, 2026; 1.33 until July 2026.
  # Update this default as versions rotate out of standard support.
  default     = "1.32"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS API server public endpoint. Default 0.0.0.0/0 is open — restrict to your IP/VPN in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway (cost-saving for dev). Set to false for production — a single NAT gateway is a cross-AZ SPOF per AWS Well-Architected REL-BP-02."
  type        = bool
  default     = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password (no default — must be set via tfvars, env, or -var)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.grafana_admin_password) >= 12
    error_message = "Grafana admin password must be at least 12 characters."
  }
}
