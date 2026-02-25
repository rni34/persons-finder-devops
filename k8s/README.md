# Kubernetes Manifests — Persons Finder

## Manifest Inventory

| File | Kind | Purpose |
|------|------|---------|
| `namespace.yaml` | Namespace | Creates the `persons-finder` namespace |
| `resource-quota.yaml` | ResourceQuota | CPU/memory quotas for the namespace |
| `limit-range.yaml` | LimitRange | Default container resource limits |
| `external-secret.yaml` | ServiceAccount, SecretStore, ExternalSecret | Syncs OPENAI_API_KEY from AWS Secrets Manager |
| `deployment.yaml` | Deployment, ServiceAccount | Application workload with full security hardening |
| `service.yaml` | Service | ClusterIP service exposing port 80 → 8080 |
| `ingress.yaml` | Ingress | ALB ingress with TLS termination |
| `hpa.yaml` | HorizontalPodAutoscaler | CPU-based autoscaling (2–10 replicas) |
| `pdb.yaml` | PodDisruptionBudget | Guarantees at least 1 pod during disruptions |
| `network-policy.yaml` | NetworkPolicy | Restricts ingress/egress traffic |
| `service-monitor.yaml` | ServiceMonitor | Prometheus scrape config for /actuator/prometheus |
| `prometheus-rules.yaml` | PrometheusRule | Alerting rules (down, restarts, errors, memory) |
| `grafana-dashboard.yaml` | ConfigMap | 12-panel Grafana dashboard (auto-loaded via sidecar) |

## Apply Order

Use Kustomize for correct ordering:

```bash
kubectl apply -k k8s/
```

Manual order if needed:
1. `namespace.yaml` — namespace must exist first
2. `resource-quota.yaml`, `limit-range.yaml` — governance before workloads
3. `external-secret.yaml` — secrets before deployment
4. `deployment.yaml` — the application
5. `service.yaml` — expose the deployment
6. `ingress.yaml` — external access
7. `hpa.yaml`, `pdb.yaml` — scaling and availability
8. `network-policy.yaml` — network security
9. `service-monitor.yaml`, `prometheus-rules.yaml`, `grafana-dashboard.yaml` — monitoring

## Security Features

Every manifest follows EKS and Kubernetes security best practices:
- Non-root container (UID/GID 1000)
- Read-only root filesystem
- All capabilities dropped
- Seccomp RuntimeDefault profile
- SA token not auto-mounted
- Network egress restricted to DNS + HTTPS
- Secrets from AWS Secrets Manager via IRSA (no hardcoded values)
