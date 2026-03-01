# Kubernetes Manifests — Persons Finder

## Manifest Inventory

| File | Kind | Purpose |
|------|------|---------|
| `namespace.yaml` | Namespace, ServiceAccount | Creates namespace with PSS restricted + default SA token disabled |
| `resource-quota.yaml` | ResourceQuota | CPU/memory quotas for the namespace |
| `limit-range.yaml` | LimitRange | Default container resource limits |
| `admission-policy.yaml` | ValidatingAdmissionPolicy, Binding | Restricts container images to ECR registries in PII namespaces (K8s 1.30+ built-in) |
| `external-secret.yaml` | ServiceAccount, SecretStore, ExternalSecret | Syncs OPENAI_API_KEY from AWS Secrets Manager via IRSA |
| `priority-class.yaml` | PriorityClass | Ensures app pods are scheduled before lower-priority workloads |
| `deployment.yaml` | Deployment, ServiceAccount | Application workload with full security hardening |
| `service.yaml` | Service | ClusterIP service: port 80 → 8080 (app), port 8081 → 8081 (management) |
| `ingress.yaml` | Ingress | ALB ingress with TLS, WAF, access logs, slow start |
| `hpa.yaml` | HorizontalPodAutoscaler | CPU-based autoscaling (2–10 replicas) |
| `pdb.yaml` | PodDisruptionBudget | Limits disruption to 1 pod at a time (maxUnavailable: 1) |
| `default-deny.yaml` | NetworkPolicy | Default-deny ingress/egress baseline for all pods in namespace |
| `network-policy.yaml` | NetworkPolicy | App-specific allow rules: ingress 8080/8081, egress DNS + HTTPS |
| `service-monitor.yaml` | ServiceMonitor | Prometheus scrape config for /actuator/prometheus on management port |
| `prometheus-rules.yaml` | PrometheusRule | Alerting rules: availability, errors, latency, memory, OOM, HPA ceiling |
| `alertmanager-config.yaml` | AlertmanagerConfig | Routes alerts to Slack (warning) and PagerDuty (critical) |
| `grafana-dashboard.yaml` | ConfigMap | 14-panel Grafana dashboard (auto-loaded via sidecar) |

## Apply Order

Use Kustomize for correct ordering:

```bash
kubectl apply -k k8s/
```

Manual order if needed:
1. `namespace.yaml` — namespace must exist first
2. `resource-quota.yaml`, `limit-range.yaml`, `admission-policy.yaml` — governance before workloads
3. `external-secret.yaml` — secrets before deployment
4. `deployment.yaml` — the application
5. `service.yaml` — expose the deployment
6. `ingress.yaml` — external access
7. `hpa.yaml`, `pdb.yaml` — scaling and availability
8. `network-policy.yaml` — network security
9. `service-monitor.yaml`, `prometheus-rules.yaml`, `alertmanager-config.yaml`, `grafana-dashboard.yaml` — monitoring

## Security Features

Every manifest follows EKS and Kubernetes security best practices:
- Non-root container (UID/GID 1000)
- Read-only root filesystem
- All capabilities dropped
- Seccomp RuntimeDefault profile
- SA token not auto-mounted
- Network egress restricted to DNS + HTTPS
- Secrets from AWS Secrets Manager via IRSA (no hardcoded values)
