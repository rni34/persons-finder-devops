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

## Prometheus Not Scraping

**Symptom:** No metrics in Grafana, Prometheus targets page shows the target as down.

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets
```

**Common causes:**
- ServiceMonitor not discovered — ensure `serviceMonitorSelectorNilUsesHelmValues: false` in the Prometheus Helm values.
- Service port not named — the ServiceMonitor references `port: http`, which must match the Service port name.
- NetworkPolicy blocking scrape — ensure the NetworkPolicy allows ingress from the monitoring namespace on port 8080.

## Grafana Dashboard Empty

**Symptom:** Dashboard loads but all panels show "No data".

**Common causes:**
- Prometheus datasource not configured — check Grafana > Configuration > Data Sources.
- Wrong namespace in queries — the dashboard uses a `$namespace` variable defaulting to `persons-finder`.
- Metrics not exposed — verify the app exposes `/actuator/prometheus`: `kubectl port-forward -n persons-finder svc/persons-finder 8080:80 && curl localhost:8080/actuator/prometheus`
