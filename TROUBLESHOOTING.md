# Troubleshooting — Persons Finder

## Pod CrashLoopBackOff

**Symptom:** Pod restarts repeatedly, status shows `CrashLoopBackOff`.

```bash
kubectl logs -n persons-finder deploy/persons-finder --previous
kubectl describe pod -n persons-finder -l app=persons-finder
```

**Common causes:**
- Missing `OPENAI_API_KEY` secret — check ExternalSecret sync: `kubectl get externalsecret -n persons-finder`
- OOM killed — check `kubectl describe pod` for `OOMKilled` reason. Increase memory limits in deployment.yaml.
- JVM startup failure — check if the container image exists and is pullable.

## ExternalSecret Not Syncing

**Symptom:** `kubectl get externalsecret -n persons-finder` shows `SecretSyncedError`.

```bash
kubectl describe externalsecret openai-api-key -n persons-finder
kubectl logs -n external-secrets deploy/external-secrets
```

**Common causes:**
- IRSA role not configured — verify the `eso-sa` ServiceAccount has the correct `eks.amazonaws.com/role-arn` annotation.
- Secret doesn't exist in Secrets Manager — create it: `aws secretsmanager create-secret --name persons-finder/openai-api-key --region us-east-1`
- IAM policy too restrictive — ensure the ESO role has `secretsmanager:GetSecretValue` and `secretsmanager:DescribeSecret` on the secret ARN.

## Secrets Manager Unavailable

**Symptom:** ExternalSecret shows `SecretSyncedError`, but running pods are unaffected.

**Impact analysis:**
- **Running pods:** Unaffected. `OPENAI_API_KEY` env var is injected at pod startup and doesn't change during the pod's lifetime.
- **New pods (scale-up, rolling update):** Start normally. The K8s Secret `openai-secret` persists in etcd regardless of provider availability (`deletionPolicy: Retain`). Value is stale but present.
- **First-time deployment:** Fails. ESO can't create the K8s Secret → pods fail with `CreateContainerConfigError` because the `secretKeyRef` can't be resolved.

**Diagnose:**
```bash
# Check ExternalSecret status
kubectl get externalsecret -n persons-finder
kubectl describe externalsecret openai-api-key -n persons-finder

# Check if K8s Secret still exists (it should)
kubectl get secret openai-secret -n persons-finder

# Check ESO controller logs for retry behavior
kubectl logs -n external-secrets deploy/external-secrets --tail=50
```

**ESO retry behavior:** The controller retries on each `refreshInterval` (1h). Between intervals, the controller-runtime reconciliation loop uses exponential backoff. The K8s Secret is never deleted on refresh failure due to `deletionPolicy: Retain`.

**Resolve:**
1. Check AWS Health Dashboard for Secrets Manager service status
2. Verify VPC endpoints / NAT gateway connectivity to Secrets Manager
3. Force immediate re-sync once SM recovers: `kubectl annotate externalsecret openai-api-key -n persons-finder force-sync=$(date +%s) --overwrite`

## HPA Not Scaling

**Symptom:** `kubectl get hpa -n persons-finder` shows `<unknown>` for current metrics.

```bash
kubectl top pods -n persons-finder
kubectl get apiservice v1beta1.metrics.k8s.io
```

**Common causes:**
- metrics-server not running — check `kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server`
- Resource requests not set — HPA needs `resources.requests.cpu` in the deployment to calculate utilization.

## ALB Not Created

**Symptom:** `kubectl get ingress -n persons-finder` shows no ADDRESS.

```bash
kubectl logs -n kube-system deploy/aws-load-balancer-controller
kubectl describe ingress persons-finder -n persons-finder
```

**Common causes:**
- LB controller not installed — check `kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`
- Missing subnet tags — public subnets need `kubernetes.io/role/elb: 1`
- IRSA role misconfigured — check the controller service account annotation.

## Image Pull Errors

**Symptom:** Pod shows `ImagePullBackOff` or `ErrImagePull`.

```bash
kubectl describe pod -n persons-finder -l app=persons-finder | grep -A5 Events
```

**Common causes:**
- Image doesn't exist in ECR — verify: `aws ecr describe-images --repository-name persons-finder --region us-east-1`
- Node can't reach ECR — nodes must be in private subnets with NAT gateway, or have VPC endpoints for ECR.
- Wrong image tag — check the tag in deployment.yaml matches what was pushed.

## ECR Unavailable

**Symptom:** New pods show `ImagePullBackOff`; running pods are unaffected.

**Impact analysis:**
- **Running pods:** Unaffected. Container is already running; no image pull needed.
- **New pods on nodes with cached image:** Start normally. `imagePullPolicy: IfNotPresent` skips the pull when the image exists in the node's container runtime cache.
- **New pods on nodes without cached image:** Fail with `ErrImagePull` → `ImagePullBackOff` (exponential backoff: 10s, 20s, 40s… capped at 5min).
- **Rolling updates (same image tag):** Succeed on nodes with cache; fail on nodes without. `maxUnavailable: 0` prevents old pods from terminating until new pods are Ready, so existing capacity is preserved.
- **Rolling updates (new image tag):** Fail on all nodes — new tag is not cached anywhere. Deployment stalls with `maxUnavailable: 0` protecting existing pods.
- **HPA scale-up:** May fail if scheduler places pods on nodes without the cached image.
- **New nodes (ASG scale-out, spot replacement):** Empty cache → all pods on that node fail until ECR recovers.

**Why `IfNotPresent` is correct:** `Always` would make every pod startup depend on ECR availability, including restarts of existing pods. With immutable ECR tags, `IfNotPresent` is safe — the tag can never point to a different image.

**Diagnose:**
```bash
# Check which nodes have the image cached
kubectl get pods -n persons-finder -o wide
# Pods in Running state have the image cached on their node

# Test ECR connectivity from a node
kubectl run ecr-test --rm -it --image=amazonlinux -- \
  curl -s -o /dev/null -w "%{http_code}" https://<account>.dkr.ecr.<region>.amazonaws.com/v2/

# Check AWS service health
# https://health.aws.amazon.com — look for ECR in the affected region
```

**Resolve:**
1. Check [AWS Health Dashboard](https://health.aws.amazon.com) for ECR service status
2. Verify NAT gateway is healthy: `aws ec2 describe-nat-gateways --filter Name=state,Values=available`
3. For production, add ECR Interface VPC endpoints (`ecr.api` + `ecr.dkr`) to eliminate NAT dependency — see `terraform/vpc-endpoints.tf` comments
4. Enable ECR cross-region replication for DR — see RUNBOOK.md Disaster Recovery section

## Availability Zone Failure

**Symptom:** Nodes in one AZ show `NotReady`; pods on those nodes enter `Terminating` state.

**Impact analysis:**
- **Running pods in healthy AZs:** Unaffected. ALB cross-zone load balancing routes traffic to healthy targets automatically.
- **Pods on failed AZ nodes:** Evicted after 60s (`tolerationSeconds` on `node.kubernetes.io/unreachable`). Scheduler places replacements in healthy AZs — `topologySpreadConstraints` with `ScheduleAnyway` allows temporary zone skew.
- **ALB traffic:** ALB health checks detect unhealthy targets within seconds and stop routing to them. No manual intervention needed.
- **NAT gateway (`single_nat_gateway=true`):** If the failed AZ hosts the single NAT gateway, ALL private subnets lose internet access — pods can't reach external LLM, ECR pulls fail, ESO can't reach Secrets Manager. Set `single_nat_gateway=false` for production.
- **HPA:** Remaining pods absorb load; HPA scales up if CPU exceeds 70% target. ASG launches new nodes in healthy AZs.

**Diagnose:**
```bash
# Check node status — look for NotReady nodes
kubectl get nodes -o wide

# Check which AZ is affected
kubectl get nodes -L topology.kubernetes.io/zone

# Check pod distribution across AZs
kubectl get pods -n persons-finder -o wide

# Check NAT gateway health (critical if single_nat_gateway=true)
aws ec2 describe-nat-gateways --filter Name=state,Values=available \
  --query 'NatGateways[].{AZ:SubnetId,State:State}' --output table
```

**Resolve:**
1. Verify ALB is routing only to healthy targets: check target group in AWS Console or `aws elbv2 describe-target-health`
2. Confirm replacement pods are scheduling: `kubectl get pods -n persons-finder -o wide` — new pods should appear on nodes in healthy AZs within ~90s (60s eviction + scheduling)
3. If NAT is down (single gateway in failed AZ), pods lose external connectivity — escalate to AWS Support and consider enabling per-AZ NAT gateways (`single_nat_gateway=false`)
4. For production, enable [EKS zonal shift](https://docs.aws.amazon.com/eks/latest/userguide/zone-shift.html) with ARC for automated traffic redirection during AZ impairments

**Recovery:** When the AZ recovers, nodes return to `Ready` status. ASG rebalances nodes across AZs. New pod scheduling respects topology spread constraints, gradually restoring even distribution.

## Prometheus Unavailable

**Symptom:** Grafana dashboards show gaps, alerts stop firing, Watchdog dead man's snitch pages on-call.

**Impact analysis:**

- **Alerting gap:** All PrometheusRule alerts (PersonsFinderDown, HighErrorRate, HighP99Latency, HighMemoryUsage, HighRestartCount) stop evaluating. If the app goes down while Prometheus is down, nobody is notified. The Watchdog alert (dead man's switch) stops firing, triggering the external snitch service to page on-call.
- **Dashboard gap:** Grafana panels show "No data" for the outage window. Historical data up to the failure point is preserved (based on Prometheus retention, default 7d). The gap is permanent — Prometheus cannot backfill missed scrapes.
- **HPA impact:** None. HPA uses `type: Resource` (CPU utilization) sourced from metrics-server, not Prometheus. Autoscaling continues normally during Prometheus outages.
- **Running pods:** Unaffected. Prometheus is observability-only — no runtime dependency.

```bash
# Check Prometheus pod status
kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
# Check Prometheus storage — no storageSpec configured, uses emptyDir.
# ALL metrics data is lost on pod restart (not just during downtime).
# For production, add storageSpec to kube-prometheus-stack Helm values.
kubectl get pvc -n monitoring  # Expected: empty (no PVC)
# Check Prometheus operator logs for reconciliation errors
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-operator --tail=50
```

**Recovery:** Prometheus auto-recovers on pod restart (StatefulSet). Scraping resumes immediately. **All historical metrics are lost** — Prometheus uses emptyDir (no persistent volume), so pod restart means full data loss, not just a gap. The 7-day retention setting only applies within a single pod lifecycle. For production, configure `storageSpec` in the kube-prometheus-stack Helm values to use a PersistentVolumeClaim. Verify Watchdog alert resumes firing after recovery.

## Prometheus Not Scraping

**Symptom:** No metrics in Grafana, Prometheus targets page shows the target as down.

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets
```

**Common causes:**
- ServiceMonitor not discovered — ensure `serviceMonitorSelectorNilUsesHelmValues: false` in the Prometheus Helm values.
- Service port not named — the ServiceMonitor references `port: management`, which must match the Service port name.
- NetworkPolicy blocking scrape — ensure the NetworkPolicy allows ingress from the monitoring namespace on port 8081.

## Grafana Dashboard Empty

**Symptom:** Dashboard loads but all panels show "No data".

**Common causes:**
- Prometheus datasource not configured — check Grafana > Configuration > Data Sources.
- Wrong namespace in queries — the dashboard uses a `$namespace` variable defaulting to `persons-finder`.
- Metrics not exposed — verify the app exposes `/actuator/prometheus`: `kubectl port-forward -n persons-finder svc/persons-finder 8081:8081 && curl localhost:8081/actuator/prometheus`

## 502/504 Errors During Rolling Updates

**Symptom:** Brief spike of 502 or 504 errors when deploying a new version.

```bash
# Check ALB target group deregistration
kubectl get ingress -n persons-finder -o yaml | grep target-group-attributes
# Check pod termination timing
kubectl get deploy persons-finder -n persons-finder -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}'
```

**Common causes:**
- Missing pod readiness gate — without the `elbv2.k8s.aws/pod-readiness-gate-inject: enabled` label on the namespace, K8s considers new pods "ready" when the readiness probe passes, but the ALB target group may still show them as "Initial". Old pods get terminated before new pods are healthy in ALB → no healthy targets → 502. Verify: `kubectl get pod -o wide` should show READINESS GATES column as `1/1`.
- Deregistration delay > pod lifetime — if ALB's deregistration delay (default 300s) exceeds `terminationGracePeriodSeconds` (45s), ALB routes to already-killed pods. Fixed: `deregistration_delay.timeout_seconds=30` in ingress annotations.
- preStop too short — the 10s `preStop` sleep allows endpoint removal to propagate before SIGTERM. If reduced, ALB may still route traffic during shutdown.
- Spring Boot shutdown timeout — `server.shutdown=graceful` with 30s timeout. Requests in-flight at SIGTERM get 30s to complete.
