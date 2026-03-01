# Runbook — Persons Finder

Operational procedures for common incidents. Each section follows: Detect → Diagnose → Resolve → Verify.

## Pod OOMKilled

**Detect:** Alert `HighMemoryUsage` fires, or `kubectl get pods` shows `OOMKilled` restart reason.

**Diagnose:**
```bash
kubectl describe pod -n persons-finder -l app=persons-finder | grep -A3 "Last State"
kubectl top pods -n persons-finder
```

**Resolve:**
1. Increase memory limit in `k8s/deployment.yaml` (current: 1Gi limit)
2. Check for memory leaks: `kubectl port-forward -n persons-finder svc/persons-finder 8081:8081` then `curl localhost:8081/actuator/metrics/jvm.memory.used`
3. If JVM heap is the issue, adjust `-XX:MaxRAMPercentage` in Dockerfile ENTRYPOINT

**Verify:** `kubectl get pods -n persons-finder` shows Running, no restarts.

## HPA Maxed Out

**Detect:** `kubectl get hpa -n persons-finder` shows REPLICAS = MAXREPLICAS (10).

**Diagnose:**
```bash
kubectl get hpa -n persons-finder -o wide
kubectl top pods -n persons-finder
```

**Resolve:**
1. If CPU is genuinely high: increase `maxReplicas` in `k8s/hpa.yaml`
2. If CPU is low but HPA shows high: check for metric lag, wait 5 minutes
3. If sustained: scale the node group: `aws eks update-nodegroup-config --cluster-name persons-finder --nodegroup-name <name> --scaling-config desiredSize=4`

**Verify:** `kubectl get hpa -n persons-finder` shows current replicas < max.

## Secret Rotation

**When:** Rotating the OpenAI API key.

**Steps:**
```bash
# 1. Update the secret in AWS Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id persons-finder/openai-api-key \
  --secret-string '{"OPENAI_API_KEY":"sk-new-key-here"}' \
  --region us-east-1

# 2. ESO will sync within refreshInterval (1h). To force immediate sync:
kubectl annotate externalsecret openai-api-key -n persons-finder force-sync=$(date +%s) --overwrite

# 3. Restart pods to pick up the new secret
kubectl rollout restart deployment/persons-finder -n persons-finder
```

**Verify:** `kubectl get externalsecret -n persons-finder` shows `SecretSynced`.

## EKS Cluster Version Upgrade

Upgrade order: **control plane → addons → node groups**. EKS supports one minor version skip at a time (e.g., 1.32 → 1.33, not 1.32 → 1.34). Check the [EKS version calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) for support dates.

### Pre-Upgrade Checklist

```bash
# 1. Check current versions
kubectl version --short
aws eks describe-cluster --name persons-finder --query 'cluster.version'

# 2. Check for deprecated APIs your manifests use
# Install: https://github.com/doitintl/kube-no-trouble
kubent

# 3. Verify addon compatibility with target version
aws eks describe-addon-versions --kubernetes-version 1.33 \
  --query 'addons[?addonName==`coredns` || addonName==`kube-proxy` || addonName==`vpc-cni`].[addonName,addonVersions[0].addonVersion]' \
  --output table

# 4. Ensure PDB allows rolling updates
kubectl get pdb -n persons-finder
```

### Upgrade with Terraform

```bash
# 1. Bump cluster_version in terraform.tfvars (or variables.tf default)
#    cluster_version = "1.33"

# 2. Plan — should show only control plane + addon updates (not node replacement)
cd terraform
terraform plan -target=module.eks

# 3. Apply control plane upgrade (~10-15 min, zero downtime)
terraform apply -target=module.eks

# 4. Apply full stack (triggers node group rolling update)
terraform apply
```

The managed node group performs a rolling update automatically: new nodes launch with the new AMI, pods are drained from old nodes (respecting PDB), old nodes terminate.

### Post-Upgrade Validation

```bash
# Control plane version
kubectl version --short

# All nodes on new version
kubectl get nodes -o wide

# Pods healthy
kubectl get pods -n persons-finder
kubectl get pods -n kube-system

# Addons updated
aws eks describe-addon --cluster-name persons-finder --addon-name vpc-cni \
  --query 'addon.addonVersion'
```

## Node Drain

**Before draining:**
```bash
# Check PDB allows disruption
kubectl get pdb -n persons-finder

# Verify at least 2 replicas running
kubectl get pods -n persons-finder
```

**Drain:**
```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

PDB guarantees `maxUnavailable: 1` — only one pod evicted at a time during drain.

**Verify:** `kubectl get pods -n persons-finder -o wide` shows pods redistributed to remaining nodes.

## Rollback Deployment

```bash
# Check rollout history
kubectl rollout history deployment/persons-finder -n persons-finder

# Rollback to previous version
kubectl rollout undo deployment/persons-finder -n persons-finder

# Verify
kubectl rollout status deployment/persons-finder -n persons-finder
```

## ALB Not Routing Traffic

**Diagnose:**
```bash
kubectl get ingress -n persons-finder
kubectl describe ingress persons-finder -n persons-finder
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

**Common fixes:**
- No ADDRESS: LB controller not running or IRSA misconfigured
- 502/503: Pods not ready, check readiness probe
- 404: Ingress path mismatch

## Grafana Dashboard Missing Data

```bash
# Check Prometheus is scraping
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets — look for persons-finder target

# Check ServiceMonitor exists
kubectl get servicemonitor -n persons-finder

# Check metrics endpoint
kubectl port-forward -n persons-finder svc/persons-finder 8081:8081
curl -s localhost:8081/actuator/prometheus | head -20
```

## Emergency: Scale to Zero

If the app is causing issues and needs to be taken offline immediately:

```bash
kubectl scale deployment/persons-finder -n persons-finder --replicas=0
```

To restore: `kubectl scale deployment/persons-finder -n persons-finder --replicas=2` (or let HPA manage it).

## Disaster Recovery

### Classification

| Property | Value | Rationale |
|----------|-------|-----------|
| **RPO** | ~0 (near-zero) | Stateless app — no persistent data. All state lives in external systems (git, ECR, Secrets Manager). |
| **RTO** | ~30 minutes | Terraform cluster creation (~15 min) + manifest deployment (~5 min) + DNS propagation (~10 min). |

### Recovery Sources

| Component | Source | Recovery Method |
|-----------|--------|-----------------|
| K8s manifests | Git repository | `git clone` + `kubectl apply -k k8s/` |
| Container image | ECR | Already pushed; enable cross-region replication for multi-region DR |
| Infrastructure | Terraform state in S3 | `terraform init` + `terraform apply` (S3 versioning recovers corrupted state) |
| Secrets | AWS Secrets Manager | Recreate secret value; enable multi-region replication for automated failover |
| Cluster config | Terraform | Full cluster recreatable from code — no manual config drift |

### Full Region Failure — Recovery Steps

```bash
# 1. Switch to DR region
export AWS_REGION=us-west-2

# 2. Recreate infrastructure
cd terraform
terraform init -backend-config="bucket=persons-finder-tfstate-dr" \
               -backend-config="region=us-west-2"
terraform apply

# 3. Configure kubectl
aws eks update-kubeconfig --region us-west-2 --name persons-finder

# 4. Ensure secret exists in DR region
aws secretsmanager put-secret-value \
  --secret-id persons-finder/openai-api-key \
  --secret-string '{"OPENAI_API_KEY":"sk-..."}' \
  --region us-west-2

# 5. Deploy application
kubectl apply -k k8s/

# 6. Verify
kubectl get pods -n persons-finder
kubectl get externalsecret -n persons-finder
```

### Preventive Measures

- **ECR cross-region replication**: Configure replication rules to replicate images to DR region automatically.
- **Secrets Manager replication**: Use `aws secretsmanager replicate-secret-to-regions` for automatic secret sync.
- **Terraform state**: S3 bucket versioning is enabled; enable cross-region replication for the state bucket.
- **DNS failover**: Use Route 53 health checks with failover routing to switch traffic to DR region automatically.
