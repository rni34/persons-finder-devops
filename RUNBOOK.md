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
2. Check for memory leaks: `kubectl port-forward -n persons-finder svc/persons-finder 8080:80` then `curl localhost:8080/actuator/metrics/jvm.memory.used`
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

## Node Drain / Cluster Upgrade

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

PDB guarantees `minAvailable: 1` — at least one pod stays running during drain.

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
kubectl port-forward -n persons-finder svc/persons-finder 8080:80
curl -s localhost:8080/actuator/prometheus | head -20
```

## Emergency: Scale to Zero

If the app is causing issues and needs to be taken offline immediately:

```bash
kubectl scale deployment/persons-finder -n persons-finder --replicas=0
```

To restore: `kubectl scale deployment/persons-finder -n persons-finder --replicas=2` (or let HPA manage it).
