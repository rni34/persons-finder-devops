# ---------- VPC Endpoints ----------
# Keeps AWS API traffic on the AWS backbone instead of routing through NAT gateway.
# Benefits: reduced NAT data processing costs, improved security, better reliability.

# S3 Gateway Endpoint (free) — ECR stores image layers in S3, so this
# eliminates NAT charges for every docker pull on every node.
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = module.vpc.vpc_id
  service_name = "com.amazonaws.${var.region}.s3"

  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${var.cluster_name}-s3-endpoint"
  }
}

# NOTE: For production, add Interface endpoints for these services to eliminate
# all NAT dependency for AWS API calls (~$7.20/month each):
#   - com.amazonaws.<region>.ecr.api       (ECR API calls)
#   - com.amazonaws.<region>.ecr.dkr       (ECR Docker registry)
#   - com.amazonaws.<region>.sts           (IRSA token exchange)
#   - com.amazonaws.<region>.secretsmanager (ESO secret fetches)
#   - com.amazonaws.<region>.logs          (CloudWatch log shipping)
