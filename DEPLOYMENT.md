# Deployment Guide — Persons Finder

Step-by-step instructions to deploy the Persons Finder application on AWS EKS.

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- Terraform >= 1.7 (required by `required_version = "~> 1.7"` in `terraform/main.tf`)
- kubectl
- Docker
- Gradle (or use the included `./gradlew` wrapper)

## 1. Provision Infrastructure (Terraform)

```bash
cd terraform

# Initialize providers
terraform init

# Review the plan
terraform plan -out=tfplan

# Apply
terraform apply tfplan
```

This creates:
- VPC with public/private subnets across 3 AZs, VPC Flow Logs (CloudWatch, 30-day retention)
- EKS cluster (v1.32) with managed node group (AL2023), managed addons (CoreDNS, kube-proxy, VPC-CNI)
- EKS control plane logging (all 5 types: api, audit, authenticator, scheduler, controllerManager)
- ECR repository (immutable tags, scan-on-push)
- AWS Secrets Manager secret for OPENAI_API_KEY + KMS key for encryption
- IAM roles for ESO and AWS Load Balancer Controller
- WAF WebACL with AWS managed rules (OWASP, SQLi, Log4Shell) + rate limiting
- S3 bucket for ALB access logs (90-day retention, SSE-S3 encrypted — ALB log delivery does not support SSE-KMS)
- S3 VPC gateway endpoint (free, eliminates NAT costs for S3/ECR traffic)
- GuardDuty with EKS audit log analysis + runtime monitoring (container-level threat detection)
- SNS topic for security notifications — GuardDuty MEDIUM+ findings and ECR CRITICAL scan findings routed via EventBridge
- WAF request logging to CloudWatch (blocked requests only, sensitive headers redacted)
- kube-prometheus-stack (Prometheus + Grafana)
- metrics-server (required for HPA)
- External Secrets Operator

## 2. Configure kubectl

```bash
# Use the output from Terraform
aws eks update-kubeconfig --region us-east-1 --name persons-finder
```

## 3. Set the OpenAI API Key

```bash
aws secretsmanager put-secret-value \
  --secret-id persons-finder/openai-api-key \
  --secret-string '{"OPENAI_API_KEY":"sk-your-key-here"}' \
  --region us-east-1
```

## 4. Build and Push the Docker Image

```bash
# Get your ECR repository URL from Terraform output
ECR_URL=$(cd terraform && terraform output -raw ecr_repository_url)

# Build
make docker-build

# Login to ECR (extract registry URL from repository URL)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin "${ECR_URL%%/*}"

# Push (override Makefile default with your ECR repo)
ECR_REPO="${ECR_URL}" make docker-push
```

## 5. Deploy Kubernetes Resources

Update the following values in K8s manifests before applying. All Terraform outputs can be retrieved with `cd terraform && terraform output`.

| File | Value to Update | Source |
|---|---|---|
| `k8s/deployment.yaml` | `image:` (line 78) | `terraform output ecr_repository_url` + `:$(git rev-parse --short HEAD)` |
| `k8s/external-secret.yaml` | `eks.amazonaws.com/role-arn` annotation (line 12) | `terraform output eso_role_arn` |
| `k8s/external-secret.yaml` | `region:` in SecretStore spec (line 28) | Must match `var.region` in Terraform |
| `k8s/ingress.yaml` | `certificate-arn` annotation | Your ACM certificate ARN |
| `k8s/ingress.yaml` | `wafv2-acl-arn` annotation | `terraform output waf_acl_arn` |
| `k8s/ingress.yaml` | `access_logs.s3.bucket=` in load-balancer-attributes | `terraform output alb_access_logs_bucket` |

```bash
# Apply all manifests via Kustomize
make deploy
# or: kubectl apply -k k8s/
```

Apply order (handled automatically by Kustomize):
1. Namespace + governance (ResourceQuota, LimitRange)
2. Secrets (ExternalSecret + SecretStore)
3. Workloads (Deployment, Service, Ingress)
4. Scaling (HPA, PDB)
5. Network (NetworkPolicy)
6. Monitoring (ServiceMonitor, PrometheusRules, Grafana dashboard)

## 6. Verify Deployment

```bash
# Check pods are running
kubectl get pods -n persons-finder

# Check the external secret synced
kubectl get externalsecret -n persons-finder

# Check HPA is active
kubectl get hpa -n persons-finder

# Check the ALB was created
kubectl get ingress -n persons-finder

# Test the health endpoint
kubectl port-forward -n persons-finder svc/persons-finder 8081:8081
curl http://localhost:8081/actuator/health
```

## 7. Subscribe to Security Notifications

Terraform creates an SNS topic for GuardDuty findings (MEDIUM+) and ECR image scan findings (CRITICAL), but the topic has no subscribers by default. Without a subscription, security alerts are silently dropped.

```bash
# Get the SNS topic ARN
SNS_ARN=$(cd terraform && terraform output -raw security_notifications_topic_arn)

# Subscribe via email (confirm the subscription link sent to your inbox)
aws sns subscribe --topic-arn "$SNS_ARN" --protocol email --notification-endpoint <your-team-email> --region us-east-1

# Or subscribe a Slack/PagerDuty webhook
aws sns subscribe --topic-arn "$SNS_ARN" --protocol https --notification-endpoint https://hooks.slack.com/services/YOUR/WEBHOOK/URL --region us-east-1
```

## 8. Access Grafana

```bash
# Port-forward to Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Open http://localhost:3000
# Credentials: admin / <your grafana_admin_password from tfvars>
# Dashboard: "Persons Finder" (auto-loaded via sidecar)
```

## Local Development

For local observability without a cluster:

```bash
# Start the app
./gradlew bootRun

# Start Prometheus + Grafana
make monitoring-up

# Access:
#   App:        http://localhost:8080
#   Actuator:   http://localhost:8080/actuator/prometheus
#   Prometheus: http://localhost:9090
#   Grafana:    http://localhost:3000 (admin/admin)

# Stop
make monitoring-down
```

> **Note:** Locally, actuator endpoints serve on port 8080 (Spring Boot default). In K8s, `MANAGEMENT_SERVER_PORT=8081` moves actuator to a separate port to prevent internet exposure via ALB. The local Prometheus config (`observability/prometheus.yml`) scrapes port 8080 to match.

## Teardown

Three resources have `lifecycle { prevent_destroy = true }` to guard against accidental deletion:
- `aws_kms_key.secrets` — deletion makes all encrypted secrets permanently unrecoverable
- `aws_secretsmanager_secret.openai_api_key` — API key lost
- `aws_ecr_repository.app` — all container images deleted

To fully destroy the infrastructure, remove these lifecycle blocks first:

```bash
# 1. Remove K8s resources
make undeploy

# 2. Remove prevent_destroy from secrets.tf and eso.tf
#    Delete or comment out the lifecycle { prevent_destroy = true } blocks in:
#      terraform/secrets.tf   (aws_kms_key.secrets, aws_secretsmanager_secret.openai_api_key)
#      terraform/eso.tf       (aws_ecr_repository.app)

# 3. Destroy infrastructure
cd terraform && terraform destroy
```
