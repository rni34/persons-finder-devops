# ---------- Monitoring Namespace ----------
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
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
  version    = "58.2.2"

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

  # Prometheus retention
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
