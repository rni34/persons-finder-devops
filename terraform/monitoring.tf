# ---------- Monitoring Namespace ----------
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      # PSS: node-exporter requires hostNetwork, hostPID, and hostPath volumes,
      # so enforce must be privileged. Audit/warn at baseline catches anything
      # beyond what the monitoring stack legitimately needs.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }

  depends_on = [module.eks]
}

# ---------- kube-prometheus-stack ----------
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  # NOT auto-updated by Dependabot — check manually:
  # https://github.com/prometheus-community/helm-charts/releases
  version    = "58.2.2"

  # Reliability: auto-rollback on failure prevents FAILED release state.
  # Timeout raised from default 300s — this chart deploys CRDs, Prometheus,
  # Alertmanager, Grafana, node-exporter, kube-state-metrics; on a cold
  # cluster with image pulls, 300s can be insufficient.
  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  # Discover ServiceMonitors across all namespaces
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues"
    value = "false"
  }

  # AlertmanagerConfig discovery — without these, AlertmanagerConfig CRDs
  # outside the monitoring namespace (e.g., k8s/alertmanager-config.yaml in
  # persons-finder namespace) are silently ignored. Alertmanager only picks up
  # configs matching Helm release labels by default, and only in its own namespace.
  # This broke the Slack/PagerDuty routing added in iteration #19.
  set {
    name  = "alertmanager.alertmanagerSpec.alertmanagerConfigSelectorNilUsesHelmValues"
    value = "false"
  }

  # alertmanagerConfigNamespaceSelector: {} (empty object) means "all namespaces".
  # Nil (default) means "Alertmanager's own namespace only" — which would miss
  # the AlertmanagerConfig in persons-finder namespace. Helm `set` can't express
  # an empty object, so we use `values` with YAML.
  values = [yamlencode({
    alertmanager = {
      alertmanagerSpec = {
        alertmanagerConfigNamespaceSelector = {}
      }
    }
  })]

  # Prometheus retention — only effective within a single pod lifecycle.
  # No storageSpec configured: Prometheus uses emptyDir, so ALL metrics are
  # lost on pod restart. Acceptable for dev; for production, add:
  #   set { name = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"; value = "50Gi" }
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "7d"
  }

  # Grafana config
  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  set {
    name  = "grafana.service.type"
    value = "ClusterIP"
  }

  # Auto-load dashboards from ConfigMaps with grafana_dashboard label
  set {
    name  = "grafana.sidecar.dashboards.searchNamespace"
    value = "ALL"
  }

  depends_on = [module.eks, helm_release.metrics_server]
}
