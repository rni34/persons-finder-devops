# Deployment Guide — Persons Finder

Step-by-step instructions to deploy the Persons Finder application on AWS EKS.

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- Terraform >= 1.3.0
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
- VPC with public/private subnets across 3 AZs
- EKS cluster (v1.29) with managed node group
- ECR repository (immutable tags, scan-on-push)
- AWS Secrets Manager secret for OPENAI_API_KEY
- IAM roles for ESO and AWS Load Balancer Controller
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
# Build
make docker-build

# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin 637423556985.dkr.ecr.us-east-1.amazonaws.com

# Push
make docker-push
```

## 5. Deploy Kubernetes Resources

```bash
# Update the image tag in k8s/deployment.yaml to match your pushed image

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
kubectl port-forward -n persons-finder svc/persons-finder 8080:80
curl http://localhost:8080/actuator/health
```

## 7. Access Grafana

```bash
# Port-forward to Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Open http://localhost:3000
# Default credentials: admin / prom-operator (or your configured password)
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
#   Prometheus: http://localhost:9090
#   Grafana:    http://localhost:3000 (admin/admin)

# Stop
make monitoring-down
```

## Teardown

```bash
# Remove K8s resources
make undeploy

# Destroy infrastructure
cd terraform && terraform destroy
```
