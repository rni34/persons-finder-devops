# ADR-003: /19 Private Subnets for EKS VPC CNI

## Status
Accepted

## Context
EKS with VPC CNI assigns one VPC IP address per pod. The original /24 subnets (254 IPs) support the current workload (t3.medium × 4 nodes × 17 pods/node = 68 pods per AZ) but leave zero headroom for DaemonSets, HPA burst scaling, additional services, or node group expansion. /24 subnet exhaustion is the #1 cause of pod scheduling failures in EKS clusters that grow beyond initial sizing.

## Decision
Use /19 private subnets (8,190 IPs per AZ) within the existing /16 VPC CIDR. Public subnets remain /24 (only ALBs and NAT gateways).

## Consequences
- 32x IP headroom per AZ eliminates pod scheduling failures from IP exhaustion
- No cost impact — VPC IPs are free; only ENIs attached to running instances incur charges
- Engineers must not shrink subnets back to /24 without calculating: (max nodes × max pods per node × AZ count) + DaemonSet overhead + HPA burst headroom
